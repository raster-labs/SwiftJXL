// SPDX-License-Identifier: Apache-2.0
// Owning public API simulator smoke probe; no testable imports or runtime oracle.
import Foundation
import Darwin
import SwiftJXL

private struct ProbeFailure: Error { let message: String }
/// Cancels after real destination writes, while the owning provider is still
/// retained. No borrowed pointer crosses an async boundary.
private final class CancellingOutputOwner: WritableImageStorage {
    let owner: OwnedImageStorage
    init(bytes: Int) throws { owner = try OwnedImageStorage(byteCount: bytes) }
    var byteCount: Int { owner.byteCount }
    var allocationID: UUID { owner.allocationID }
    func reserveWrite() throws -> StorageWriteLease { try owner.reserveWrite() }
    func withUnsafeMutableBytes<R>(lease: StorageWriteLease,
        _ body: (UnsafeMutableRawBufferPointer) throws -> R) throws -> R {
        let result = try owner.withUnsafeMutableBytes(lease: lease, body)
        withUnsafeCurrentTask { $0?.cancel() }
        return result
    }
    func finishAndSeal(lease: StorageWriteLease) throws -> any ReadOnlyImageStorage {
        try owner.finishAndSeal(lease: lease)
    }
    func abortAndInvalidate(lease: StorageWriteLease) throws { try owner.abortAndInvalidate(lease: lease) }
}
@main struct AppleRuntimeProbe {
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw ProbeFailure(message: message) }
    }
    static func limits(_ memory: Int = 32 * 1024 * 1024) throws -> ResourceLimits {
        try ResourceLimits(maximumCompressedBytes: 1024 * 1024, maximumDecodedBytes: 1024 * 1024,
            maximumWorkspaceBytes: memory, maximumPixels: 4096, maximumDimension: 256,
            maximumFrames: 8, maximumMetadataBytes: 65536, maximumICCBytes: 65536,
            maximumWorkers: 1, deadlineSeconds: 30, maximumMemoryBytes: memory)
    }
    static func run() async throws -> [String: Any] {
        guard CommandLine.arguments.count == 2 else { throw ProbeFailure(message: "Expected fixture directory") }
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        let cap = try limits(), decodeOptions = DecodeOptions(resourceLimits: cap, copyPolicy: .requireSharedStorage)
        let encodeOptions = EncodeOptions(resourceLimits: cap, copyPolicy: .requireSharedStorage)
        let descriptor = try ImageDescriptor.greyscale16(width: 3, height: 2, meaningfulBits: 12, rowBytes: 8)
        let destination = try ImageDestination.allocate(descriptor: descriptor, limits: cap)
        let image = try destination.write { bytes in
            for y in 0..<2 { for x in 0..<3 {
                let sample = UInt16((y * 3 + x) * 819), offset = y * 8 + x * 2
                bytes[offset] = UInt8(truncatingIfNeeded: sample); bytes[offset + 1] = UInt8(sample >> 8)
            } }
        }
        let encoder = try Encoder(), decoder = try Decoder()
        let encoded = try await encoder.encode(image, options: encodeOptions)
        let decoded = try await decoder.decode(encoded.data, options: decodeOptions)
        try require(try decoded.image.sampleUInt16(x: 2, y: 1) == 4095 && decoded.image.descriptor.meaningfulBits == 12, "12-bit samples")
        try require(encoded.report.copyEvents.isEmpty && decoded.report.copyEvents.isEmpty, "Shared storage report")
        let target = try ImageDestination.allocate(descriptor: decoded.image.descriptor, limits: cap)
        let targetID = target.storage.allocationID
        let direct = try await decoder.decode(encoded.data, into: target, options: decodeOptions)
        try require(direct.image.storage.allocationID == targetID, "Destination owner identity")
        let sequence = try await encoder.encodeAnimation([
            try AnimationInputFrame(image: image, durationTicks: 10),
            try AnimationInputFrame(image: image, durationTicks: 25)
        ], animation: .init(ticksPerSecondNumerator: 100, ticksPerSecondDenominator: 1001, loopCount: 3), options: encodeOptions)
        let frames = try await decoder.decodeAll(sequence.encoded.data, options: decodeOptions)
        try require(frames.frames.count == 2 && frames.timing?.totalTicks == 35 && frames.timing?.loopCount == 3
            && frames.timing?.ticksPerSecondDenominator == 1001 && frames.frames.map(\.durationTicks) == [10,25], "Animation timing")
        try require(frames.frames[0].decoded.image.storage.allocationID != frames.frames[1].decoded.image.storage.allocationID, "Distinct frame owners")
        try require(try frames.frames[0].decoded.image.sampleUInt16(x: 2, y: 1) == 4095, "Retained first frame")
        let jxl = try Data(contentsOf: fixtures.appendingPathComponent("precision-12-1.jxl"))
        let reference = try Data(contentsOf: fixtures.appendingPathComponent("precision-12-1.scalar"))
        let lossy = try await decoder.decode(jxl, options: decodeOptions)
        try require(lossy.image.descriptor.meaningfulBits == 12 && lossy.report.fidelity == .lossy, "VarDCT precision/fidelity")
        try require(reference.count == 17 * 9 * 4, "Reference size")
        var peak = 0, squares = 0.0
        for y in 0..<9 { for x in 0..<17 {
            let raw = reference.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: (y * 17 + x) * 4, as: UInt32.self) }
            let expected = Int((Double(min(1, max(0, Float(bitPattern: UInt32(littleEndian: raw))))) * 4095).rounded())
            let actual = Int(try lossy.image.sampleUInt16(x: x, y: y)), delta = abs(actual - expected)
            peak = max(peak, delta); squares += Double(delta * delta)
        } }
        let rms = sqrt(squares / 153)
        try require(peak <= 2 && rms <= 0.5, "Independent VarDCT numerical gate")
        let alphaData = try Data(contentsOf: fixtures.appendingPathComponent("libjxl-lossless-rgba16.jxl"))
        let alpha = try await decoder.decodeAll(alphaData, options: decodeOptions)
        try require(alpha.frames.count == 3 && alpha.timing?.totalTicks == 60, "Independent alpha animation timing")
        for frame in alpha.frames {
            let bytes = try frame.decoded.image.storage.withUnsafeBytes { Data($0) }
            try require(bytes.count == 16 * 9 * 4 * 2, "Alpha frame storage")
            for i in 0..<(16 * 9 * 4) {
                let actual = Int(bytes[i * 2]) | Int(bytes[i * 2 + 1]) << 8
                try require(actual == (i * 257 + frame.index * 769) % 65536, "Independent exact RGBA16 samples")
            }
        }
        do {
            _ = try await decoder.decode(encoded.data, options: .init(resourceLimits: limits(100_000)))
            throw ProbeFailure(message: "Low memory accepted")
        } catch let error as CodecError { try require(error.category == .resourceLimitExceeded, "Defined low-memory rejection") }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await decoder.decode(encoded.data, options: decodeOptions)
        }
        do { _ = try await cancelled.value; throw ProbeFailure(message: "Cancellation ignored") }
        catch is CancellationError {}
        let interruptedOwner = try CancellingOutputOwner(bytes: descriptor.requiredByteCount)
        let interruptedDestination = try ImageDestination(descriptor: descriptor, storage: interruptedOwner, limits: cap)
        let interrupted = Task { try await decoder.decode(encoded.data, into: interruptedDestination, options: decodeOptions) }
        do { _ = try await interrupted.value; throw ProbeFailure(message: "Cancelled output published") }
        catch is CancellationError {}
        do { _ = try interruptedOwner.reserveWrite(); throw ProbeFailure(message: "Failed destination reused") }
        catch let error as CodecError { try require(error.category == .storageUnavailable, "Invalidated destination") }
        try require(ResourceLimits.watch.maximumWorkspaceBytes == 32 * 1024 * 1024 &&
            ResourceLimits.watch.maximumDecodedBytes == 32 * 1024 * 1024 &&
            ResourceLimits.watch.maximumWorkers == 2 && ResourceLimits.watch.deadlineSeconds == 30, "Watch profile")
        #if os(watchOS)
        try require(ResourceLimits.default == .watch, "Watch default selection")
        #endif
        let watchEncoded = try await encoder.encode(image, options: .init(resourceLimits: .watch))
        let watchDecoded = try await decoder.decode(watchEncoded.data, options: .init(resourceLimits: .watch))
        try require(try watchDecoded.image.sampleUInt16(x: 2, y: 1) == 4095, "Watch profile exact output")
        let wrapped = try await Encoder(configuration: .init(codecOptions: .init(container: .iso)))
            .encode(image, options: encodeOptions)
        let fromContainer = try await decoder.decode(wrapped.data, options: decodeOptions)
        try require(wrapped.report.copyEvents.count == 1 &&
            fromContainer.image.sampleUInt16(x: 2, y: 1) == 4095, "Explicit pixel container")
        let jpeg = try Data(contentsOf: fixtures.appendingPathComponent("gray.jpg"))
        let jpegReference = try Data(contentsOf: fixtures.appendingPathComponent("gray.raw"))
        let jpegPixels = try await decoder.decodeJPEG(jpeg, interpretingAs: .srgb, options: decodeOptions)
        let jpegBytes = try jpegPixels.image.storage.withUnsafeBytes { Data($0) }
        try require(jpegBytes.count == jpegReference.count && jpegPixels.report.pixelAllocationCount == 1,
            "JPEG pixel owner and shape")
        var jpegSquares = 0.0, jpegPeak = 0
        for i in 0..<jpegBytes.count {
            let delta = abs(Int(jpegBytes[i]) - Int(jpegReference[i]))
            jpegPeak = max(jpegPeak, delta); jpegSquares += Double(delta * delta)
        }
        try require(jpegPeak <= 2 && sqrt(jpegSquares / Double(jpegBytes.count)) <= 0.75, "Independent JPEG pixel gate")
        let extended = fixtures.appendingPathComponent("JPEGExtended")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: extended.appendingPathComponent("manifest.json")))
        guard let cases = manifest as? [[String: Any]], !cases.isEmpty else { throw ProbeFailure(message: "Missing extended JPEG cases") }
        for entry in cases {
            guard let name = entry["name"] as? String, let expected = entry["samples"] as? [Int],
                  let bits = entry["precision"] as? Int, let interpretation = entry["interpretation"] as? String else {
                throw ProbeFailure(message: "Invalid extended JPEG fixture manifest")
            }
            let bytes = try Data(contentsOf: extended.appendingPathComponent(name + ".jpg"))
            let mode: JPEGPixelInterpretation = interpretation == "srgb" ? .srgb : .embedded(orientation: .preserve)
            let info = try decoder.inspectJPEG(bytes, interpretingAs: mode, options: decodeOptions)
            let result = try await decoder.decodeJPEG(bytes, interpretingAs: mode, options: decodeOptions)
            let d = result.image.descriptor
            try require(d == info.descriptor && d.meaningfulBits == bits, "Extended JPEG descriptor")
            let samples = try result.image.storage.withUnsafeBytes { raw -> [Int] in
                if d.storageBits == 8 { return raw.map(Int.init) }
                return stride(from: 0, to: raw.count, by: 2).map { Int(raw[$0]) | Int(raw[$0 + 1]) << 8 }
            }
            try require(samples == expected, "Extended JPEG exact reference samples")
            let target = try ImageDestination.allocate(descriptor: d, limits: cap)
            let id = target.storage.allocationID
            let direct = try await decoder.decodeJPEG(bytes, interpretingAs: mode, into: target, options: decodeOptions)
            try require(direct.image.storage.allocationID == id && direct.report.pixelAllocationCount == 0,
                        "Extended JPEG caller owner")
            if name == "exif-6-True" {
                let oriented = try await decoder.decodeJPEG(bytes, interpretingAs: .embedded(orientation: .apply), options: decodeOptions)
                let values = try oriented.image.storage.withUnsafeBytes { $0.map(Int.init) }
                try require(oriented.image.descriptor.width == 2 && oriented.image.descriptor.height == 3
                    && values == [4,1,5,2,6,3], "Explicit JPEG orientation application")
            }
            if name == "icc-gray" {
                try require(d.iccProfile == Data(contentsOf: extended.appendingPathComponent("gray.icc")), "JPEG ICC preservation")
            }
        }
        return ["status":"passed", "jpegExtendedCases": cases.count, "memoryCeilingBytes":32 * 1024 * 1024, "varDCTPeakLSB":peak, "varDCTRMSLSB":rms,
                "checks":["12-bit lossless", "caller destination owner", "shared-storage reports", "exact animation timing", "separate retained frame owners", "independent VarDCT12", "independent RGBA16 animation", "low-memory rejection", "cancellation", "cancellation after destination writes", "failed destination invalidation", "Watch profile and exact round trip", "explicit pixel container", "independent JPEG pixel decoding", "extended JPEG precision metadata and ownership"]]
    }
    static func main() async {
        do {
            let result = try await run()
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            print("PROBE FAILED: \(error)")
            exit(1)
        }
    }
}
