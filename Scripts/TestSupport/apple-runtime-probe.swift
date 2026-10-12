// SPDX-License-Identifier: Apache-2.0
// Owning public API simulator smoke probe; no testable imports or runtime oracle.
import Foundation
import Darwin
import SwiftJXL

private struct ProbeFailure: Error { let message: String }
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
        return ["status":"passed", "memoryCeilingBytes":32 * 1024 * 1024, "varDCTPeakLSB":peak, "varDCTRMSLSB":rms,
                "checks":["12-bit lossless", "caller destination owner", "shared-storage reports", "exact animation timing", "separate retained frame owners", "independent VarDCT12", "independent RGBA16 animation", "low-memory rejection", "cancellation"]]
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
