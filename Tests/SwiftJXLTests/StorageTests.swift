// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import SwiftJXL

private final class TestCounters: Sendable {
    let deallocations = Mutex(0)
    let active = Mutex(0)
    let overlap = Mutex(false)
}

private final class ReadAdapter: ReadOnlyImageStorage, Sendable {
    let owner: any ReadOnlyImageStorage
    let counters: TestCounters
    var byteCount: Int { owner.byteCount }
    var allocationID: UUID { owner.allocationID }
    init(_ owner: any ReadOnlyImageStorage, counters: TestCounters) {
        self.owner = owner
        self.counters = counters
    }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        try owner.withUnsafeBytes(body)
    }
    deinit { counters.deallocations.withLock { $0 += 1 } }
}

@Suite("Owning storage")
struct StorageTests {
    @Test func leaseCannotBeForgedReusedOrBorrowedReentrantly() throws {
        let owner = try OwnedImageStorage(byteCount: 4)
        let lease = try owner.reserveWrite()
        expectCodecError(.storageUnavailable) { _ = try owner.reserveWrite() }
        expectCodecError(.storageUnavailable) {
            try owner.withUnsafeMutableBytes(lease: StorageWriteLease()) { _ in }
        }
        try owner.withUnsafeMutableBytes(lease: lease) { bytes in
            bytes[0] = 0xFE
            expectCodecError(.storageUnavailable) {
                try owner.withUnsafeMutableBytes(lease: lease) { _ in }
            }
            expectCodecError(.storageUnavailable) { _ = try owner.finishAndSeal(lease: lease) }
            expectCodecError(.storageUnavailable) { try owner.abortAndInvalidate(lease: lease) }
            expectCodecError(.storageUnavailable) { _ = try owner.reserveWrite() }
        }
        let sealed = try owner.finishAndSeal(lease: lease)
        #expect(try sealed.withUnsafeBytes { $0[0] } == 0xFE)
        #expect(sealed.allocationID == owner.allocationID)
        expectCodecError(.storageUnavailable) {
            try owner.withUnsafeMutableBytes(lease: lease) { _ in }
        }
        expectCodecError(.storageUnavailable) { _ = try owner.finishAndSeal(lease: lease) }
        expectCodecError(.storageUnavailable) { _ = try owner.reserveWrite() }
    }

    @Test func abortMakesStorageUnreadableAndUnwritable() throws {
        let owner = try OwnedImageStorage(byteCount: 8)
        let lease = try owner.reserveWrite()
        try owner.withUnsafeMutableBytes(lease: lease) { $0[0] = 42 }
        try owner.abortAndInvalidate(lease: lease)
        expectCodecError(.storageUnavailable) { _ = try owner.finishAndSeal(lease: lease) }
        expectCodecError(.storageUnavailable) {
            try owner.withUnsafeMutableBytes(lease: lease) { _ in }
        }
        expectCodecError(.storageUnavailable) { _ = try owner.reserveWrite() }
    }

    @Test func throwingBorrowReleasesAdmissionWithoutReplacingStorage() throws {
        enum ExpectedFailure: Error { case stop }
        let owner = try OwnedImageStorage(byteCount: 2)
        let lease = try owner.reserveWrite()
        #expect(throws: ExpectedFailure.self) {
            try owner.withUnsafeMutableBytes(lease: lease) { bytes in
                bytes[0] = 42
                throw ExpectedFailure.stop
            }
        }
        try owner.withUnsafeMutableBytes(lease: lease) { bytes in
            #expect(bytes[0] == 42)
            bytes[1] = 19
        }
        let sealed = try owner.finishAndSeal(lease: lease)
        #expect(sealed.allocationID == owner.allocationID)
        #expect(try sealed.withUnsafeBytes { Array($0) } == [42, 19])
    }

    @Test func freshAllocationsHaveDistinctIdentitiesAndZeroPadding() throws {
        let descriptor = try ImageDescriptor.greyscale16(width: 3, height: 2, rowBytes: 8, offset: 2)
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        let image = try destination.write { bytes in
            bytes[2] = 0xFF
            bytes[3] = 0xFF
        }
        let second = try ImageDestination.allocate(descriptor: descriptor).write { _ in }
        #expect(image.storage.allocationID != second.storage.allocationID)
        try image.storage.withUnsafeBytes { bytes in
            for index in bytes.indices where index != 2 && index != 3 {
                #expect(bytes[index] == 0)
            }
        }
    }

    @Test func imageRetainsAdapterAndAllocationUntilLastReader() throws {
        let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1)
        let sealed = try ImageDestination.allocate(descriptor: descriptor).write { bytes in
            bytes[0] = 0xFF; bytes[1] = 0xFF
        }
        let counters = TestCounters()
        var adapter: ReadAdapter? = ReadAdapter(sealed.storage, counters: counters)
        weak var observed = adapter
        var image: Image? = try Image(descriptor: descriptor, storage: try #require(adapter))
        adapter = nil
        #expect(observed != nil)
        #expect(try image?.storage.withUnsafeBytes { UInt16($0[0]) | UInt16($0[1]) << 8 } == 65535)
        image = nil
        #expect(observed == nil)
        #expect(counters.deallocations.withLock { $0 } == 1)
        observed = nil
    }

    @Test func rejectsOwnerCapacityShorterThanDescriptor() throws {
        let owner = try OwnedImageStorage(byteCount: 2)
        let lease = try owner.reserveWrite()
        let sealed = try owner.finishAndSeal(lease: lease)
        let descriptor = try ImageDescriptor.greyscale16(width: 2, height: 1)
        expectCodecError(.incompatibleImageLayout) {
            _ = try Image(descriptor: descriptor, storage: sealed)
        }
    }

    @Test func concurrentReadersPreserveEveryLogicalSample() async throws {
        let descriptor = try ImageDescriptor.greyscale16(width: 3, height: 2, meaningfulBits: 12, rowBytes: 8)
        let expected: [UInt16] = [0, 4095, 1, 2048, 17, 4094]
        let image = try ImageDestination.allocate(descriptor: descriptor).write { bytes in
            for index in 0..<6 {
                let offset = (index / 3) * 8 + (index % 3) * 2
                bytes[offset] = UInt8(truncatingIfNeeded: expected[index])
                bytes[offset + 1] = UInt8(expected[index] >> 8)
            }
        }
        try await withThrowingTaskGroup(of: [UInt16].self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try image.storage.withUnsafeBytes { bytes in
                        (0..<6).map { index in
                            let offset = (index / 3) * 8 + (index % 3) * 2
                            return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                        }
                    }
                }
            }
            for try await values in group { #expect(values == expected) }
        }
    }

    @Test func copiedLeaseCannotOverlapWriters() async throws {
        let owner = try OwnedImageStorage(byteCount: 2)
        let lease = try owner.reserveWrite()
        let counters = TestCounters()
        let successes = try await withThrowingTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    do {
                        try owner.withUnsafeMutableBytes(lease: lease) { bytes in
                            counters.active.withLock { value in
                                value += 1
                                if value != 1 { counters.overlap.withLock { $0 = true } }
                            }
                            Thread.sleep(forTimeInterval: 0.001)
                            bytes[0] += 1
                            counters.active.withLock { $0 -= 1 }
                        }
                        return 1
                    } catch let error as CodecError where error.category == .storageUnavailable {
                        return 0
                    }
                }
            }
            var total = 0
            for try await result in group { total += result }
            return total
        }
        let sealed = try owner.finishAndSeal(lease: lease)
        #expect(successes > 0)
        #expect(!counters.overlap.withLock { $0 })
        #expect(try sealed.withUnsafeBytes { Int($0[0]) } == successes)
    }
}
