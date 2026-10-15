// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct JPEGPixelPublicTests {
    static let fixtures = ["gray", "444", "422", "420", "440", "progressive", "restart",
        "progressive-422", "progressive-440", "progressive-edge", "sequential-multiscan"]
    private func jpeg(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "jpg", subdirectory: "JPEG")))
    }
    @Test(arguments: fixtures) func layoutsPreserveSamplesOwnerAndPadding(_ name: String) async throws {
        let input = try jpeg(name), decoder = try Decoder()
        let decoded = try await decoder.decodeJPEG(input, interpretingAs: .srgb)
        let d = decoded.image.descriptor
        #expect(decoded.report.fidelity == .lossy && decoded.report.pixelAllocationCount == 1)
        #expect(decoded.report.copyEvents.isEmpty && d.meaningfulBits == 8 && d.storageBits == 8)
        let reference = try decoded.image.storage.withUnsafeBytes { Array($0) }
        for bigEndian in [false, true] {
            var planes: [PlaneDescriptor] = [], offset = 6
            for c in d.components.indices.reversed() {
                let row = d.width * 4 + 6, end = offset + row * d.height + 8
                planes.append(try PlaneDescriptor(width: d.width, height: d.height, components: [c], offset: offset,
                    sampleStride: 2, pixelStride: 4, rowBytes: row, byteCount: end))
                offset = end + 10
            }
            let destinationDescriptor = try ImageDescriptor(width: d.width, height: d.height,
                storageBits: 16, meaningfulBits: 8, byteOrder: bigEndian ? .bigEndian : .littleEndian,
                components: d.components, colour: d.colour, planes: planes)
            let storage = try JPEGPixelSentinelStorage(byteCount: destinationDescriptor.requiredByteCount)
            let destination = try ImageDestination(descriptor: destinationDescriptor, storage: storage)
            // Expected byte positions also prove no duplicated full-image handoff.
            let audit = ScalarStorageAudit()
            let result = try await ScalarStorageAudit.$current.withValue(audit) {
                try await decoder.decodeJPEG(input, interpretingAs: .srgb, into: destination)
            }
            #expect(audit.snapshot.finalPixelAllocations == 0 && result.report.pixelAllocationCount == 0)
            #expect(result.image.storage.allocationID == storage.allocationID && result.report.copyEvents.isEmpty)
            let actual = try result.image.storage.withUnsafeBytes { Array($0) }
            var expected = [UInt8](repeating: 0xA5, count: actual.count)
            for plane in planes {
                let c = try #require(plane.components.first)
                for y in 0..<d.height { for x in 0..<d.width {
                    let p = plane.offset + y * plane.rowBytes + x * plane.pixelStride
                    expected[p + (bigEndian ? 1 : 0)] = reference[(y * d.width + x) * d.components.count + c]
                    expected[p + (bigEndian ? 0 : 1)] = 0
                } }
            }
            #expect(actual == expected)
        }
        let sliced = (Data([1, 2, 3]) + input).dropFirst(3)
        let same = try await decoder.decodeJPEG(sliced, interpretingAs: .srgb)
        #expect(try same.image.storage.withUnsafeBytes { Array($0) } == reference)
    }
    @Test func metadataLimitsAndCancellationRejectWithoutPublishing() async throws {
        let input = try jpeg("444"), decoder = try Decoder()
        for limits in try [ResourceLimits(maximumCompressedBytes: 1), ResourceLimits(maximumDecodedBytes: 1),
            ResourceLimits(maximumWorkspaceBytes: 1), ResourceLimits(maximumMemoryBytes: 1),
            ResourceLimits(maximumDimension: 1), ResourceLimits(maximumPixels: 1), ResourceLimits(deadlineSeconds: 1e-100)] {
            do { _ = try await decoder.decodeJPEG(input, interpretingAs: .srgb, options: .init(resourceLimits: limits)); Issue.record("Ignored JPEG pixel limit") }
            catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
        }
        for (marker, payload) in [(UInt8(0xe1), Data("Exif\0\0".utf8)), (UInt8(0xe2), Data("ICC_PROFILE\0".utf8) + Data([1, 1]))] {
            let length = payload.count + 2
            let injected = input.prefix(2) + Data([255, marker, UInt8(length >> 8), UInt8(length & 255)]) + payload + input.dropFirst(2)
            do { _ = try await decoder.decodeJPEG(injected, interpretingAs: .srgb, options: .init(metadataPolicy: .discardAncillary)); Issue.record("Discarded required JPEG interpretation") }
            catch let error as CodecError { #expect(error.category == .unsupportedFeature) }
        }
        for data in [Data(), Data(input.prefix(input.count / 2))] {
            do { _ = try await decoder.decodeJPEG(data, interpretingAs: .srgb); Issue.record("Accepted truncated JPEG") }
            catch let error as CodecError { #expect(error.category == .malformedInput) }
        }
        let descriptor = try decoder.inspectJPEG(input, interpretingAs: .srgb).descriptor
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        let cancelled = Task {
            try await decoder.decodeJPEG(input, interpretingAs: .srgb, into: destination, options: .init(progress: { update in
                if update.phase == .completed { withUnsafeCurrentTask { $0?.cancel() } }
            }))
        }
        do { _ = try await cancelled.value; Issue.record("Published cancelled JPEG output") }
        catch is CancellationError {}
        do { _ = try destination.write { _ in }; Issue.record("Reused invalidated JPEG destination") }
        catch let error as CodecError { #expect(error.category == .storageUnavailable) }
    }
    @Test func boundedMalformedCorpusAndConcurrentOwners() async throws {
        let source = try jpeg("gray"), decoder = try Decoder()
        let limits = try ResourceLimits(maximumCompressedBytes: 65536, maximumDecodedBytes: 65536,
            maximumWorkspaceBytes: 32 * 1024 * 1024, maximumPixels: 16384, maximumDimension: 128,
            deadlineSeconds: 5, maximumMemoryBytes: 64 * 1024 * 1024)
        // Deterministic truncation and marker/entropy mutations. A valid mutation
        // may decode; malformed data must never trap, escape limits or hang.
        var corpus = [Data]()
        for count in stride(from: 0, to: source.count, by: max(1, source.count / 24)) { corpus.append(Data(source.prefix(count))) }
        for offset in stride(from: 2, to: source.count, by: max(1, source.count / 24)) {
            var changed = source; changed[offset] ^= 0xff; corpus.append(changed)
        }
        for bytes in corpus {
            do {
                let value = try await decoder.decodeJPEG(bytes, interpretingAs: .srgb, options: .init(resourceLimits: limits))
                #expect(value.image.storage.byteCount <= limits.maximumDecodedBytes)
            } catch let error as CodecError {
                #expect([.malformedInput, .unsupportedFeature, .resourceLimitExceeded].contains(error.category))
            }
        }
        let values = try await withThrowingTaskGroup(of: DecodedImage.self) { group in
            for _ in 0..<4 { group.addTask { try await decoder.decodeJPEG(source, interpretingAs: .srgb) } }
            var results: [DecodedImage] = []
            for try await value in group { results.append(value) }
            return results
        }
        #expect(Set(values.map { $0.image.storage.allocationID }).count == 4)
        let expected = try #require(values.first).image.storage.withUnsafeBytes { Array($0) }
        for value in values { #expect(try value.image.storage.withUnsafeBytes { Array($0) } == expected) }
    }
}

private struct JPEGPixelSentinelStorage: WritableImageStorage {
    let owner: OwnedImageStorage
    init(byteCount: Int) throws { owner = try OwnedImageStorage(byteCount: byteCount) }
    var byteCount: Int { owner.byteCount }
    var allocationID: UUID { owner.allocationID }
    func reserveWrite() throws -> StorageWriteLease { try owner.reserveWrite() }
    func withUnsafeMutableBytes<R>(lease: StorageWriteLease, _ body: (UnsafeMutableRawBufferPointer) throws -> R) throws -> R {
        try owner.withUnsafeMutableBytes(lease: lease) { bytes in
            for i in bytes.indices { bytes[i] = 0xA5 }
            return try body(bytes)
        }
    }
    func finishAndSeal(lease: StorageWriteLease) throws -> any ReadOnlyImageStorage { try owner.finishAndSeal(lease: lease) }
    func abortAndInvalidate(lease: StorageWriteLease) throws { try owner.abortAndInvalidate(lease: lease) }
}
