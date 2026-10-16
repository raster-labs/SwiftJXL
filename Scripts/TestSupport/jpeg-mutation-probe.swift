// SPDX-License-Identifier: Apache-2.0
// Test-only public JPEG entry points. Link ASan-instrumented module objects.
import Foundation
import SwiftJXL

private struct ProbeFailure: Error { let message: String }
/// Test-only owner. Canary initialisation and inspection stay within the
/// owner's exclusive mutable borrow, including when the decoder throws. Never
/// attempt to read the owner after ImageDestination has invalidated it.
private final class CanaryWriteStorage: WritableImageStorage {
    let owner: OwnedImageStorage
    let descriptor: ImageDescriptor
    init(descriptor: ImageDescriptor, limits: ResourceLimits) throws {
        self.descriptor = descriptor
        owner = try OwnedImageStorage(byteCount: descriptor.requiredByteCount, limits: limits)
    }
    var byteCount: Int { owner.byteCount }
    var allocationID: UUID { owner.allocationID }
    func reserveWrite() throws -> StorageWriteLease { try owner.reserveWrite() }
    func withUnsafeMutableBytes<R>(lease: StorageWriteLease,
        _ body: (UnsafeMutableRawBufferPointer) throws -> R) throws -> R {
        try owner.withUnsafeMutableBytes(lease: lease) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0xA5)
            let outcome = Result { try body(raw) }
            try checkCanaries(raw)
            return try outcome.get()
        }
    }
    private func requireCanary(_ valid: Bool, _ message: String) throws {
        // Public decoding preserves CodecError. A plain test error could be
        // translated to malformedInput and mistaken for an expected rejection.
        guard valid else { throw CodecError(.internalFailure, message) }
    }
    private func checkCanaries(_ raw: UnsafeMutableRawBufferPointer) throws {
        var previous = 0
        for plane in descriptor.planes {
            for i in previous..<plane.offset {
                try requireCanary(raw[i] == 0xA5, "leading canary overwritten")
            }
            for y in 0..<descriptor.height {
                let end = plane.offset + y * plane.rowBytes + descriptor.width * 2
                let next = y + 1 == descriptor.height ? plane.byteCount : plane.offset + (y + 1) * plane.rowBytes
                for i in end..<next { try requireCanary(raw[i] == 0xA5, "row canary overwritten") }
            }
            previous = plane.byteCount
        }
        for i in previous..<raw.count { try requireCanary(raw[i] == 0xA5, "trailing canary overwritten") }
    }
    func finishAndSeal(lease: StorageWriteLease) throws -> any ReadOnlyImageStorage {
        try owner.finishAndSeal(lease: lease)
    }
    func abortAndInvalidate(lease: StorageWriteLease) throws { try owner.abortAndInvalidate(lease: lease) }
}
@main struct JPEGMutationProbe {
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ProbeFailure(message: message) }
    }
    static func validate(_ decoded: DecodedImage) throws {
        let d = decoded.image.descriptor
        try require(d.sampleType == .unsignedInteger && (2...16).contains(d.meaningfulBits), "sample meaning")
        try require(decoded.image.storage.byteCount >= d.requiredByteCount, "storage extent")
        if let elapsed = decoded.report.elapsedSeconds {
            try require(elapsed.isFinite && elapsed >= 0, "non-finite elapsed report")
        }
        // Output samples are unsigned integers; their range validation also
        // prevents claiming a floating-point NaN/Inf sample was returned.
        let maximum = (1 << d.meaningfulBits) - 1
        try decoded.image.storage.withUnsafeBytes { bytes in
            for plane in d.planes { for y in 0..<d.height { for x in 0..<d.width { for c in plane.components.indices {
                let offset = plane.offset + y * plane.rowBytes + x * plane.pixelStride + c * plane.sampleStride
                let first = Int(bytes[offset])
                let value = d.storageBits == 8 ? first : d.byteOrder == .littleEndian
                    ? first | Int(bytes[offset + 1]) << 8 : first << 8 | Int(bytes[offset + 1])
                try require(value <= maximum, "sample range")
            } } } }
        }
    }
    static func padded(_ d: ImageDescriptor, limits: ResourceLimits) throws -> ImageDescriptor {
        let count = d.components.count, row = d.width * 2 + 8
        let planeBytes = row * d.height + 16
        let planes = try (0..<count).map { c in
            try PlaneDescriptor(width: d.width, height: d.height, components: [c],
                offset: c * planeBytes + 8, sampleStride: 2, pixelStride: 2,
                rowBytes: row, byteCount: (c + 1) * planeBytes)
        }
        return try ImageDescriptor(width: d.width, height: d.height, storageBits: 16,
            meaningfulBits: d.meaningfulBits, byteOrder: .bigEndian, components: d.components,
            colour: d.colour, alpha: d.alpha, planes: planes, iccProfile: d.iccProfile, limits: limits)
    }
    private enum IntendedWriteFailure: Error { case rejected }
    /// Exercise both success and throwing write callbacks, with and without a
    /// zero overwrite of a nonzero canary. The builder requires these checks.
    static func selfTestCanaries() throws {
        let limits = ResourceLimits.default
        let d = try padded(.greyscale16(width: 3, height: 2), limits: limits)
        for damaged in [false, true] { for throwing in [false, true] {
            let provider = try CanaryWriteStorage(descriptor: d, limits: limits)
            let lease = try provider.reserveWrite()
            do {
                try provider.withUnsafeMutableBytes(lease: lease) { raw in
                    raw[d.planes[0].offset] = 0 // A legitimate sample write.
                    if damaged { raw[0] = 0 }
                    if throwing { throw IntendedWriteFailure.rejected }
                }
                try require(!damaged && !throwing, "canary self-test unexpectedly accepted")
            } catch let error as CodecError {
                try require(damaged && error.category == .internalFailure, "canary self-test classification")
            } catch is IntendedWriteFailure {
                try require(!damaged && throwing, "throwing canary check was bypassed")
            }
            try provider.abortAndInvalidate(lease: lease)
        } }
    }
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 2 && args[1] == "--self-test-canaries" {
            try selfTestCanaries()
            print("{\"status\":\"passed\",\"canaryCases\":4}")
            return
        }
        guard args.count == 3 else { throw ProbeFailure(message: "expected entry and input") }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let limits = try ResourceLimits(maximumCompressedBytes: 1 << 20,
            maximumDecodedBytes: 8 << 20, maximumWorkspaceBytes: 120 << 20,
            maximumPixels: 262144, maximumDimension: 2048, maximumFrames: 1,
            maximumMetadataBytes: 65536, maximumICCBytes: 65536,
            maximumNestingDepth: 16, maximumWorkers: 1, deadlineSeconds: 3,
            maximumMemoryBytes: 128 << 20)
        let decoder = try Decoder()
        let interpretations: [JPEGPixelInterpretation] = [.srgb, .embedded(orientation: .preserve), .embedded(orientation: .apply)]
        var accepted = false, outcomes: [[String: String]] = []
        let names = ["srgb", "embedded-preserve", "embedded-apply"]
        for mode in 0..<6 {
            let index = mode % 3, interpretation = interpretations[index]
            let name = names[index] + (mode >= 3 ? "-discard" : "")
            let options = DecodeOptions(resourceLimits: limits, executionPolicy: .scalarCPU,
                metadataPolicy: mode >= 3 ? .discardAncillary : .preserve)
            do {
                switch args[1] {
                case "jpeg-inspect":
                    let info = try decoder.inspectJPEG(data, interpretingAs: interpretation, options: options)
                    try require(info.format == "jpeg" && info.frameCount == 1, "inspection shape")
                case "jpeg-decode":
                    let result = try await decoder.decodeJPEG(data, interpretingAs: interpretation, options: options)
                    try validate(result)
                    try require(result.report.pixelAllocationCount == 1 && result.report.copyEvents.isEmpty, "allocating path")
                case "jpeg-caller":
                    let info = try decoder.inspectJPEG(data, interpretingAs: interpretation, options: options)
                    let descriptor = info.descriptor
                    let d = try padded(descriptor, limits: limits)
                    let owner = try CanaryWriteStorage(descriptor: d, limits: limits)
                    let destination = try ImageDestination(descriptor: d, storage: owner, limits: limits)
                    let identity = destination.storage.allocationID
                    let result = try await decoder.decodeJPEG(data, interpretingAs: interpretation, into: destination, options: options)
                    try validate(result)
                    try require(result.image.storage.allocationID == identity && result.report.pixelAllocationCount == 0
                        && result.report.copyEvents.isEmpty, "caller owner identity")
                default: throw ProbeFailure(message: "unknown entry")
                }
                accepted = true
                outcomes.append(["interpretation": name, "status": "accepted"])
            } catch let error as CodecError {
                guard error.category != .internalFailure else { throw error }
                outcomes.append(["interpretation": name, "status": "rejected", "category": error.category.rawValue])
            }
        }
        let result: [String: Any] = ["status": accepted ? "accepted" : "rejected", "outcomes": outcomes]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
