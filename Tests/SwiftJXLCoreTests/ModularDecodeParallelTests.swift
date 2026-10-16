// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct ModularDecodeParallelTests {
    private enum ProbeError: Error { case index(Int) }
    private struct Counts: Sendable { var active = 0, peak = 0, completed = 0; var contextMatches = true }
    private func budget(workers: Int, workspace: Int = 64 * 1024 * 1024,
                        cancellation: ScalarOperationCancellation? = nil) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: workspace,
            maximumMemoryBytes: 128 * 1024 * 1024, maximumDecodedBytes: 32 * 1024 * 1024,
            maximumCompressedBytes: 16 * 1024 * 1024, deadline: .now.advanced(by: .seconds(30)),
            maximumWorkers: workers, cancellation: cancellation)
    }
    @Test(arguments: [1, 2, 8, 100])
    func boundedBatchesPreserveOrderedResultsAndAudit(_ workers: Int) throws {
        let b = try budget(workers: workers), audit = ScalarStorageAudit(), counts = Mutex(Counts())
        let result = try ScalarStorageAudit.$current.withValue(audit) {
            try modularDecodeBatch(count: b.maximumWorkers, budget: b) { index in
                counts.withLock {
                    $0.active += 1; $0.peak = max($0.peak, $0.active)
                    $0.contextMatches = $0.contextMatches && ScalarStorageAudit.current === audit
                }
                defer { counts.withLock { $0.active -= 1; $0.completed += 1 } }
                return index
            }
        }
        #expect(result == Array(0..<min(workers, 8)))
        let c = counts.withLock { $0 }, a = audit.snapshot
        #expect(c.active == 0 && c.completed == result.count && c.contextMatches)
        #expect(c.peak > 0 && c.peak <= min(workers, 8))
        #expect(a.workerJobsStarted == result.count && a.workerJobsCompleted == result.count && a.activeWorkerJobs == 0)
    }
    @Test func orderedErrorsJoinAndAdmissionPrecedesCallbacks() throws {
        let completed = Mutex(0), b = try budget(workers: 8)
        do {
            _ = try modularDecodeBatch(count: 8, budget: b) { index -> Int in
                defer { completed.withLock { $0 += 1 } }
                if index == 2 || index == 5 { throw ProbeError.index(index) }
                return index
            }
            Issue.record("Worker error discarded")
        } catch ProbeError.index(let index) { #expect(index == 2) }
        #expect(completed.withLock { $0 } == 8)
        let invoked = Mutex(false), denied = try budget(workers: 8, workspace: 1)
        #expect(throws: ScalarModularError.self) {
            try modularDecodeBatch(count: 8, budget: denied) { index in invoked.withLock { $0 = true }; return index }
        }
        #expect(!invoked.withLock { $0 })
        #expect(throws: ScalarModularError.self) { try modularDecodeBatch(count: 9, budget: b) { $0 } }
    }
    @Test func workerCancellationReachesBitReaderAndJoins() throws {
        let flag = ScalarOperationCancellation(), audit = ScalarStorageAudit()
        let b = try budget(workers: 8, cancellation: flag), completed = Mutex(0)
        #expect(throws: CancellationError.self) {
            try ScalarStorageAudit.$current.withValue(audit) {
                try modularDecodeBatch(count: 8, budget: b) { index -> Int in
                    defer { completed.withLock { $0 += 1 } }
                    var reader = BitReader(Data(), deadline: b.deadline, budget: b)
                    try reader.checkpoint()
                    flag.cancel()
                    var observed = false
                    for _ in 0..<256 {
                        do { try reader.checkpoint() }
                        catch is CancellationError { observed = true; break }
                    }
                    #expect(observed)
                    return index
                }
            }
        }
        #expect(completed.withLock { $0 } > 0)
        #expect(audit.snapshot.activeWorkerJobs == 0)
        #expect(audit.snapshot.workerJobsStarted == audit.snapshot.workerJobsCompleted)
    }
    @Test func readerKeepsItsEarlierDeadlineWithSharedBudget() throws {
        let b = try budget(workers: 2)
        var reader = BitReader(Data(), deadline: .now.advanced(by: .seconds(-1)), budget: b)
        #expect(throws: ScalarModularError.self) { try reader.checkpoint() }
    }
    private func fixture(_ name: String) throws -> Data {
        let folder = name.hasPrefix("gray2048-") ? "Modular/Parallel" : "Modular/Decoder"
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jxl", subdirectory: folder))
        return try Data(contentsOf: url)
    }
    @Test func predecessorMissingEmptyGlobalANSStateRejects() async throws {
        let data = try fixture("gray2048-predecessor-missing-empty-state")
        do {
            _ = try await Decoder().decode(data, options: .init(resourceLimits: .init(maximumWorkers: 8)))
            Issue.record("Missing empty global ANS state was accepted")
        } catch let error as CodecError {
            #expect(error.category == .malformedInput)
        }
    }
    @Test(arguments: ["groups-rgb8", "groups-rgba16", "responsive-wide-rgb8", "gray2048-gradient-ans"])
    func serialDefaultAndEightWorkersAgreeWithCallerOwnership(_ name: String) async throws {
        let data = try fixture(name), decoder = try Decoder()
        let serialAudit = ScalarStorageAudit(), parallelAudit = ScalarStorageAudit()
        let serial = try await ScalarStorageAudit.$current.withValue(serialAudit) {
            try await decoder.decode(data, options: .init(resourceLimits: .init(maximumWorkers: 1)))
        }
        let parallel = try await ScalarStorageAudit.$current.withValue(parallelAudit) {
            try await decoder.decode(data, options: .init(resourceLimits: .init(maximumWorkers: 8)))
        }
        let defaultResult = try await decoder.decode(data)
        let expected = try serial.image.storage.withUnsafeBytes { Data($0) }
        #expect(try parallel.image.storage.withUnsafeBytes { Data($0) } == expected)
        #expect(try defaultResult.image.storage.withUnsafeBytes { Data($0) } == expected)
        #expect(serialAudit.snapshot.workerJobsStarted == 0)
        #expect(parallelAudit.snapshot.workerJobsStarted > 0)
        #expect(parallelAudit.snapshot.workerJobsStarted == parallelAudit.snapshot.workerJobsCompleted)
        #expect(parallelAudit.snapshot.activeWorkerJobs == 0)
        if name == "gray2048-gradient-ans" {
            #expect(serialAudit.snapshot.workingPlaneAllocations == 0)
            #expect(parallelAudit.snapshot.workingPlaneAllocations == 16)
            #expect(parallelAudit.snapshot.workingPlaneBytes == 2048 * 2048 * 4)
            #expect(expected.count == 2048 * 2048 * 2)
            // The original benchmark PAM payload is uniformly 0x5555 (21845),
            // independently checked before decoding; see fixture provenance.
            #expect(expected.allSatisfy { $0 == 0x55 })
        }
        let d = serial.image.descriptor, channels = d.components.count, stride = channels * 2 + 2
        let rowBytes = d.width * stride + 8, capacity = 8 + d.height * rowBytes
        let plane = try PlaneDescriptor(width: d.width, height: d.height, components: Array(0..<channels),
            offset: 8, sampleStride: 2, pixelStride: stride, rowBytes: rowBytes, byteCount: capacity)
        let descriptor = try ImageDescriptor(width: d.width, height: d.height, storageBits: 16,
            meaningfulBits: d.meaningfulBits, byteOrder: .bigEndian, components: d.components,
            colour: d.colour, alpha: d.alpha, planes: [plane])
        let owner = try OwnedImageStorage(byteCount: capacity)
        let destination = try ImageDestination(descriptor: descriptor, storage: owner)
        let caller = try await decoder.decode(data, into: destination, options: .init(resourceLimits: .init(maximumWorkers: 8)))
        #expect(caller.image.storage.allocationID == owner.allocationID && caller.report.copyEvents.isEmpty)
        try caller.image.storage.withUnsafeBytes { bytes in
            var match = true
            for y in 0..<d.height { for x in 0..<d.width { for c in 0..<channels {
                let src = ((y*d.width+x)*channels+c)*2, dst = 8+y*rowBytes+x*stride+c*2
                if bytes[dst] != expected[src+1] || bytes[dst+1] != expected[src] { match = false }
            } } }
            for y in 0..<d.height {
                for x in 0..<d.width where bytes[8+y*rowBytes+x*stride+channels*2] != 0 { match = false }
                for p in (8+y*rowBytes+d.width*stride)..<(8+(y+1)*rowBytes) where bytes[p] != 0 { match = false }
            }
            #expect(match)
        }
    }
    @Test func concurrentCallsHaveIndependentOwnedResults() async throws {
        let data = try fixture("groups-rgba16"), decoder = try Decoder()
        let decoded = try await decoder.decode(data)
        let expected = try decoded.image.storage.withUnsafeBytes { Data($0) }
        let outputs = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    let decoded = try await decoder.decode(data, options: .init(resourceLimits: .init(maximumWorkers: 2)))
                    return try decoded.image.storage.withUnsafeBytes { Data($0) }
                }
            }
            var results: [Data] = []
            for try await result in group { results.append(result) }
            return results
        }
        #expect(outputs.count == 3 && outputs.allSatisfy { $0 == expected })
    }
    @Test func cancellationAfterGroupJoinInvalidatesCallerDestination() async throws {
        let data = try fixture("groups-rgba16"), decoder = try Decoder(), audit = ScalarStorageAudit()
        let destination = try ImageDestination.allocate(descriptor: decoder.inspect(data).descriptor)
        let task = Task {
            try await ScalarStorageAudit.$current.withValue(audit) {
                try await decoder.decode(data, into: destination, options: .init(
                    resourceLimits: .init(maximumWorkers: 8), progress: { update in
                        if update.phase == .completed { withUnsafeCurrentTask { $0?.cancel() } }
                    }))
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(audit.snapshot.workerJobsStarted > 0 && audit.snapshot.activeWorkerJobs == 0)
        #expect(audit.snapshot.workerJobsStarted == audit.snapshot.workerJobsCompleted)
        #expect(throws: CodecError.self) { try destination.writeUInt16 { _, _ in 0 } }
    }
}
