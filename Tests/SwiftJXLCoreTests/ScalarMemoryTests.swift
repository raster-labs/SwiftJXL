// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL
import SwiftJXLCore

struct ScalarMemoryTests {
    @Test func aggregateAdmissionIsCheckedAndOverflowCannotWrap() throws {
        let budget = try ScalarOperationBudget(retainedBytes: 10, maximumWorkspaceBytes: 20,
            maximumMemoryBytes: 40, maximumDecodedBytes: 10, maximumCompressedBytes: 10,
            deadline: .now.advanced(by: .seconds(10)))
        try budget.reservePixels(5)
        try budget.reserveOutput(5)
        try budget.reserveWorkspace(20)
        #expect(throws: ScalarModularError.self) { try budget.reserveWorkspace(1) }
        #expect(throws: ScalarModularError.self) { try budget.reservePixels(6) }
        #expect(throws: ScalarModularError.self) { try budget.reserveOutput(6) }
        #expect(budget.reservedWorkspaceBytes == 20)
        #expect(throws: ScalarModularError.self) { try budget.reserveWorkspace(Int.max) }
        #expect(throws: ScalarModularError.self) { try ScalarOperationBudget.product(Int.max, 2) }
        #expect(throws: ScalarModularError.self) { try budget.reserveWorkspace(-1) }
    }

    @Test func boundedWriterStopsGrowthAndThrowsBeforePublication() throws {
        let budget = try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: 1024,
            maximumMemoryBytes: 1024, maximumDecodedBytes: 1024, maximumCompressedBytes: 1,
            deadline: .now.advanced(by: .seconds(10)))
        let work = ScalarEncodingWork(budget: budget, writerByteLimit: 1)
        ScalarEncodingWork.$current.withValue(work) {
            var w = BitWriter(reservingBytes: 1_000_000)
            w.write(bits: 8, value: 1)
            w.write(bits: 8, value: 2)
            w.appendBytes(Data(repeating: 0, count: 10))
            #expect(w.finishToData() == Data([1]))
        }
        #expect(throws: ScalarModularError.self) { try work.checkpoint() }
    }

    @Test func publicSharedStorageUsesOnlyTheRequiredFinalAllocation() async throws {
        let descriptor = try ImageDescriptor.greyscale16(width: 128, height: 129, meaningfulBits: 12, rowBytes: 264)
        let source = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { x, y in UInt16((x * 31 + y * 7) & 4095) }
        let encodeAudit = ScalarStorageAudit()
        let encoded = try await ScalarStorageAudit.$current.withValue(encodeAudit) {
            try await Encoder().encode(source)
        }
        #expect(encodeAudit.snapshot.finalPixelAllocations == 0)
        #expect(encodeAudit.snapshot.workingPlaneAllocations == 1)
        #expect(encodeAudit.snapshot.workingPlaneBytes == 128 * 129 * 4)
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        let callerAudit = ScalarStorageAudit()
        let decoded = try await ScalarStorageAudit.$current.withValue(callerAudit) {
            try await Decoder().decode(encoded.data, into: destination)
        }
        #expect(callerAudit.snapshot.finalPixelAllocations == 0)
        #expect(callerAudit.snapshot.workingPlaneAllocations == 0)
        #expect(decoded.image.storage.allocationID == destination.storage.allocationID)
        #expect(try await Encoder().encode(decoded.image).data == encoded.data)
        let allocatingAudit = ScalarStorageAudit()
        _ = try await ScalarStorageAudit.$current.withValue(allocatingAudit) {
            try await Decoder().decode(encoded.data)
        }
        #expect(allocatingAudit.snapshot.finalPixelAllocations == 1)
        #expect(allocatingAudit.snapshot.finalPixelBytes == 128 * 129 * 2)
        #expect(allocatingAudit.snapshot.workingPlaneAllocations == 0)
    }

}
