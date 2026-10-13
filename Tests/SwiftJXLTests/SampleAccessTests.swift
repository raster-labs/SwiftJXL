// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import SwiftJXL

// Fault injection: construction sees the declared two-byte capacity, but a later
// read exposes only one byte. Image access must reject before a span load traps.
private final class ShortenedSampleBorrow: ReadOnlyImageStorage, Sendable {
    let allocationID = UUID()
    let byteCount = 2
    private let calls = Mutex(0)
    private let bytes: [UInt8] = [0x34, 0x12]

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        let count = calls.withLock { value in
            value += 1
            return value == 1 ? 2 : 1
        }
        return try bytes.withUnsafeBytes { buffer in
            try body(UnsafeRawBufferPointer(rebasing: buffer[..<count]))
        }
    }
}

// Test-only owning writable provider. All access to its raw allocation is held
// under the mutex, and only a completed fill may seal. The read wrapper retains
// this owner; sealing forbids further mutation, and deinit releases exactly once.
// Samples intentionally start uninitialised; padding is initialised before fill.
private final class UninitialisedSampleStorage: WritableImageStorage, @unchecked Sendable {
    let allocationID = UUID()
    let byteCount = 18
    private let allocation: UnsafeMutableRawPointer
    private enum Phase: Sendable { case available, writing(StorageWriteLease), sealed, invalid }
    private let phase = Mutex(Phase.available)

    init() {
        allocation = .allocate(byteCount: byteCount + 1, alignment: 2)
        let bytes = UnsafeMutableRawBufferPointer(start: allocation.advanced(by: 1), count: byteCount)
        for offset in [0, 1, 8, 9, 16, 17] { bytes[offset] = 0xa5 }
    }

    deinit { allocation.deallocate() }

    private func locked<R>(_ body: (inout Phase) throws -> R) throws -> R {
        guard let result = try phase.withLockIfAvailable({ state in try body(&state) }) else {
            throw CodecError(.storageUnavailable, "Test provider is already borrowed.")
        }
        return result
    }

    func reserveWrite() throws -> StorageWriteLease {
        try locked { phase in
            guard case .available = phase else {
                throw CodecError(.storageUnavailable, "Test provider is unavailable.")
            }
            let lease = StorageWriteLease()
            phase = .writing(lease)
            return lease
        }
    }

    func withUnsafeMutableBytes<R>(lease: StorageWriteLease,
        _ body: (UnsafeMutableRawBufferPointer) throws -> R) throws -> R {
        try locked { phase in
            guard case .writing(let current) = phase, current == lease else {
                throw CodecError(.storageUnavailable, "Test provider lease is invalid.")
            }
            return try body(UnsafeMutableRawBufferPointer(
                start: allocation.advanced(by: 1), count: byteCount))
        }
    }

    func finishAndSeal(lease: StorageWriteLease) throws -> any ReadOnlyImageStorage {
        try locked { phase in
            guard case .writing(let current) = phase, current == lease else {
                throw CodecError(.storageUnavailable, "Test provider lease is invalid.")
            }
            phase = .sealed
            return PublishedUninitialisedSamples(owner: self)
        }
    }

    func abortAndInvalidate(lease: StorageWriteLease) throws {
        try locked { phase in
            guard case .writing(let current) = phase, current == lease else {
                throw CodecError(.storageUnavailable, "Test provider lease is invalid.")
            }
            phase = .invalid
        }
    }

    func read<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        try locked { phase in
            guard case .sealed = phase else {
                throw CodecError(.storageUnavailable, "Test provider is not sealed.")
            }
            return try body(UnsafeRawBufferPointer(
                start: allocation.advanced(by: 1), count: byteCount))
        }
    }
}

private struct PublishedUninitialisedSamples: ReadOnlyImageStorage {
    let owner: UninitialisedSampleStorage
    var byteCount: Int { owner.byteCount }
    var allocationID: UUID { owner.allocationID }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        try owner.read(body)
    }
}

@Suite("Byte-order sample access")
struct SampleAccessTests {
    private func expectCategory(_ category: CodecError.Category,
                                sourceLocation: SourceLocation = #_sourceLocation,
                                _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("Expected a codec error", sourceLocation: sourceLocation)
        } catch let error as CodecError {
            #expect(error.category == category, sourceLocation: sourceLocation)
        } catch {
            Issue.record("Expected CodecError; received \(error)", sourceLocation: sourceLocation)
        }
    }

    private func descriptor(bits: Int = 16, bigEndian: Bool, padded: Bool) throws -> ImageDescriptor {
        let plane = try PlaneDescriptor(width: 3, height: 2, offset: padded ? 2 : 0,
                                        rowBytes: padded ? 8 : 6, byteCount: padded ? 18 : 12)
        return try ImageDescriptor(width: 3, height: 2, meaningfulBits: bits,
                                   byteOrder: bigEndian ? .bigEndian : .littleEndian, planes: [plane])
    }

    @Test func readsIndependentGoldenBytesFromOddPhysicalAddress() throws {
        let little: [UInt8] = [0xa5, 0xa5, 0x00, 0x00, 0xff, 0xff, 0x00, 0x80,
                               0xa5, 0xa5, 0x34, 0x12, 0x01, 0x00, 0xfe, 0xff, 0xa5, 0xa5]
        let big: [UInt8] = [0xa5, 0xa5, 0x00, 0x00, 0xff, 0xff, 0x80, 0x00,
                            0xa5, 0xa5, 0x12, 0x34, 0x00, 0x01, 0xff, 0xfe, 0xa5, 0xa5]
        let expected: [UInt16] = [0, 65535, 32768, 4660, 1, 65534]
        for isBig in [false, true] {
            let owner = UninitialisedSampleStorage()
            let destination = try ImageDestination(
                descriptor: descriptor(bigEndian: isBig, padded: true), storage: owner)
            let fixture = isBig ? big : little
            let image = try destination.write { bytes in
                for offset in fixture.indices { bytes[offset] = fixture[offset] }
            }
            try image.storage.withUnsafeBytes { bytes in
                let base = try #require(bytes.baseAddress)
                #expect(!Int(bitPattern: base).isMultiple(of: 2))
            }
            for y in 0..<2 {
                for x in 0..<3 {
                    #expect(try image.sampleUInt16(x: x, y: y) == expected[y * 3 + x])
                }
            }
        }
    }

    @Test func writesGoldenBytesForPackedAndPadded12And16BitSamples() throws {
        let values12: [UInt16] = [0, 4095, 1, 2048, 17, 4094]
        let values16: [UInt16] = [0, 65535, 32768, 4660, 1, 65534]
        let little12: [UInt8] = [0, 0, 0xff, 0x0f, 1, 0, 0, 8, 0x11, 0, 0xfe, 0x0f]
        let big12: [UInt8] = [0, 0, 0x0f, 0xff, 0, 1, 8, 0, 0, 0x11, 0x0f, 0xfe]
        let little16: [UInt8] = [0, 0, 0xff, 0xff, 0, 0x80, 0x34, 0x12, 1, 0, 0xfe, 0xff]
        let big16: [UInt8] = [0, 0, 0xff, 0xff, 0x80, 0, 0x12, 0x34, 0, 1, 0xff, 0xfe]
        for bits in [12, 16] {
            for isBig in [false, true] {
                let samples = bits == 12 ? values12 : values16
                let packed = bits == 12 ? (isBig ? big12 : little12) : (isBig ? big16 : little16)
                for padded in [false, true] {
                    let shape = try descriptor(bits: bits, bigEndian: isBig, padded: padded)
                    let destination = try ImageDestination.allocate(descriptor: shape)
                    let identity = destination.storage.allocationID
                    let image = try destination.writeUInt16 { x, y in samples[y * 3 + x] }
                    var expected = packed
                    if padded {
                        expected = [0, 0]
                        expected.append(contentsOf: packed[..<6])
                        expected.append(contentsOf: [0, 0])
                        expected.append(contentsOf: packed[6...])
                        expected.append(contentsOf: [0, 0])
                    }
                    #expect(try image.storage.withUnsafeBytes { Array($0) } == expected)
                    #expect(image.storage.allocationID == identity)
                    #expect(image.descriptor.meaningfulBits == bits)
                    for y in 0..<2 {
                        for x in 0..<3 {
                            #expect(try image.sampleUInt16(x: x, y: y) == samples[y * 3 + x])
                        }
                    }
                }
            }
        }
    }

    @Test func initialisesExternalSampleBytesAtOddAddressWithoutChangingPadding() throws {
        let samples: [UInt16] = [0, 65535, 32768, 4660, 1, 65534]
        let little: [UInt8] = [0xa5, 0xa5, 0x00, 0x00, 0xff, 0xff, 0x00, 0x80,
                               0xa5, 0xa5, 0x34, 0x12, 0x01, 0x00, 0xfe, 0xff, 0xa5, 0xa5]
        let big: [UInt8] = [0xa5, 0xa5, 0x00, 0x00, 0xff, 0xff, 0x80, 0x00,
                            0xa5, 0xa5, 0x12, 0x34, 0x00, 0x01, 0xff, 0xfe, 0xa5, 0xa5]
        for isBig in [false, true] {
            let owner = UninitialisedSampleStorage()
            let destination = try ImageDestination(
                descriptor: descriptor(bigEndian: isBig, padded: true), storage: owner)
            let image = try destination.writeUInt16 { x, y in samples[y * 3 + x] }
            try image.storage.withUnsafeBytes { bytes in
                let base = try #require(bytes.baseAddress)
                #expect(!Int(bitPattern: base).isMultiple(of: 2))
                #expect(Array(bytes) == (isBig ? big : little))
            }
            #expect(image.storage.allocationID == owner.allocationID)
        }
    }

    @Test(arguments: [1, 3, 9], [false, true])
    func stridedRowsKeepAllPaddingAndCallbackOrder(width: Int, bigEndian: Bool) throws {
        let height = 3, prefix = 2, pixelStride = 6
        let rowPayload = (width - 1) * pixelStride + 2
        let rowBytes = rowPayload + 8
        // The final row ends exactly at its last sample; no trailing padding is
        // required. Earlier rows contain both pixel gaps and eight padding bytes.
        let capacity = prefix + (height - 1) * rowBytes + rowPayload
        let plane = try PlaneDescriptor(width: width, height: height, offset: prefix,
            pixelStride: pixelStride, rowBytes: rowBytes, byteCount: capacity)
        let descriptor = try ImageDescriptor(width: width, height: height,
            byteOrder: bigEndian ? .bigEndian : .littleEndian, planes: [plane])
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        let identity = destination.storage.allocationID
        var calls: [Int] = []
        let image = try destination.writeUInt16 { x, y in
            calls.append(y * width + x)
            return UInt16(0x8100 + y * width + x)
        }
        var expected = [UInt8](repeating: 0, count: capacity)
        for y in 0..<height {
            for x in 0..<width {
                let low = UInt8(y * width + x)
                let offset = prefix + y * rowBytes + x * pixelStride
                expected[offset] = bigEndian ? 0x81 : low
                expected[offset + 1] = bigEndian ? low : 0x81
            }
        }
        #expect(calls == Array(0..<(width * height)))
        #expect(try image.storage.withUnsafeBytes { Array($0) } == expected)
        #expect(image.storage.allocationID == identity)
    }

    @Test func throwingSampleStopsInsideLaterRowAndInvalidatesDestination() throws {
        enum Stop: Error { case requested }
        let descriptor = try ImageDescriptor.greyscale16(width: 3, height: 3, rowBytes: 10)
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        var calls = 0
        #expect(throws: Stop.self) {
            _ = try destination.writeUInt16 { x, y in
                calls += 1
                if x == 1 && y == 1 { throw Stop.requested }
                return 65535
            }
        }
        #expect(calls == 5)
        expectCategory(.storageUnavailable) {
            _ = try destination.writeUInt16 { _, _ in 0 }
        }
    }

    @Test func refusesShortProviderBeforeLoadingSample() throws {
        let shape = try ImageDescriptor.greyscale16(width: 1, height: 1)
        let image = try Image(descriptor: shape, storage: ShortenedSampleBorrow())
        expectCategory(.storageUnavailable) {
            _ = try image.sampleUInt16(x: 0, y: 0)
        }
    }

    @Test func rejectsCoordinatesBeforeOffsetArithmetic() throws {
        let shape = try ImageDescriptor.greyscale16(width: 1, height: 1)
        let image = try ImageDestination.allocate(descriptor: shape).writeUInt16 { _, _ in 65535 }
        for coordinate in [-1, 1, Int.min, Int.max] {
            expectCategory(.invalidArgument) {
                _ = try image.sampleUInt16(x: coordinate, y: 0)
            }
            expectCategory(.invalidArgument) {
                _ = try image.sampleUInt16(x: 0, y: coordinate)
            }
        }
    }

    @Test func outOfPrecisionWriteInvalidatesDestination() throws {
        let shape = try ImageDescriptor.greyscale16(width: 2, height: 1, meaningfulBits: 12)
        let destination = try ImageDestination.allocate(descriptor: shape)
        expectCategory(.invalidArgument) {
            _ = try destination.writeUInt16 { x, _ in x == 0 ? 4095 : 4096 }
        }
        expectCategory(.storageUnavailable) {
            _ = try destination.writeUInt16 { _, _ in 0 }
        }
    }
}
