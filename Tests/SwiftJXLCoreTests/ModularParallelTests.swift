// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct ModularParallelTests {
    private enum ProbeError: Error { case index(Int) }
    private struct Counts: Sendable {
        var active = 0, peak = 0, completed = 0
        var contextsMatch = true
    }
    private func budget(workers: Int, workspace: Int = 64 * 1024 * 1024,
                        cancellation: ScalarOperationCancellation? = nil) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: workspace,
            maximumMemoryBytes: 128 * 1024 * 1024, maximumDecodedBytes: 16 * 1024 * 1024,
            maximumCompressedBytes: 16 * 1024 * 1024, deadline: .now.advanced(by: .seconds(30)),
            maximumWorkers: workers, cancellation: cancellation)
    }
    private func image(width: Int, height: Int, channels: Int = 1) throws -> Image {
        let roles: [ComponentRole] = channels == 1 ? [.grey] : [.red, .green, .blue, .alpha]
        let plane = try PlaneDescriptor(width: width, height: height, components: Array(roles.indices),
            sampleStride: 2, pixelStride: channels * 2, rowBytes: width * channels * 2,
            byteCount: width * height * channels * 2)
        let descriptor = try ImageDescriptor(width: width, height: height, components: roles,
            colour: channels == 1 ? .greyscale : .rgb, alpha: channels == 1 ? .absent : .straight, planes: [plane])
        return try ImageDestination.allocate(descriptor: descriptor).write { bytes in
            for index in 0..<(width * height * channels) {
                let value = (index * 71 + (index / width) * 37) & 65535
                bytes[index * 2] = UInt8(truncatingIfNeeded: value)
                bytes[index * 2 + 1] = UInt8(truncatingIfNeeded: value >> 8)
            }
        }
    }

    @Test(arguments: [1, 2, 8, 100])
    func boundedNestedWorkersPropagateContextsAndReturnOrderedResults(_ workers: Int) throws {
        let b = try budget(workers: workers), context = ScalarEncodingWork(budget: b, writerByteLimit: 1024)
        let audit = ScalarStorageAudit(), counts = Mutex(Counts())
        let results = try ScalarStorageAudit.$current.withValue(audit) {
            try ScalarEncodingWork.$current.withValue(context) {
                try parallelMap(20) { index in
                    try parallelMap(3) { nested -> Int in
                        counts.withLock {
                            $0.active += 1; $0.peak = max($0.peak, $0.active)
                            $0.contextsMatch = $0.contextsMatch && ScalarEncodingWork.current === context
                                && ScalarStorageAudit.current === audit
                        }
                        defer { counts.withLock { $0.active -= 1; $0.completed += 1 } }
                        try ScalarEncodingWork.checkpoint()
                        return index * 3 + nested
                    }
                }
            }
        }
        #expect(results.flatMap { $0 } == Array(0..<60))
        let snapshot = counts.withLock { $0 }
        #expect(snapshot.active == 0 && snapshot.completed == 60 && snapshot.contextsMatch)
        #expect(snapshot.peak >= 1 && snapshot.peak <= min(workers, 8))
        #expect(b.maximumWorkers == min(workers, 8))
    }

    @Test func errorsAreOrderedAfterJoiningAndAdmissionPrecedesCallbacks() throws {
        let completed = Mutex(0), context = ScalarEncodingWork(budget: try budget(workers: 8), writerByteLimit: 1024)
        do {
            _ = try ScalarEncodingWork.$current.withValue(context) {
                try parallelMap(20) { index -> Int in
                    defer { completed.withLock { $0 += 1 } }
                    if index == 3 || index == 7 { throw ProbeError.index(index) }
                    return index
                }
            }
            Issue.record("Worker error was discarded")
        } catch ProbeError.index(let index) { #expect(index == 3) }
        #expect(completed.withLock { $0 } == 20)
        let denied = ScalarEncodingWork(budget: try budget(workers: 8, workspace: 1), writerByteLimit: 1024)
        let invoked = Mutex(false)
        #expect(throws: ScalarModularError.self) {
            try ScalarEncodingWork.$current.withValue(denied) {
                try parallelMap(8) { index in invoked.withLock { $0 = true }; return index }
            }
        }
        #expect(!invoked.withLock { $0 })
    }

    @Test(arguments: [31, 1025], [1, 4])
    func oneAndEightWorkersProduceIdenticalStreamsAndAllocationEvents(_ width: Int, _ channels: Int) async throws {
        let source = try image(width: width, height: 7, channels: channels)
        let encoder = try Encoder(), serialAudit = ScalarStorageAudit(), parallelAudit = ScalarStorageAudit()
        let serial = try await ScalarStorageAudit.$current.withValue(serialAudit) {
            try await encoder.encode(source, options: .init(resourceLimits: .init(maximumWorkers: 1)))
        }
        let parallel = try await ScalarStorageAudit.$current.withValue(parallelAudit) {
            try await encoder.encode(source, options: .init(resourceLimits: .init(maximumWorkers: 8)))
        }
        #expect(parallel.data == serial.data)
        #expect(parallel.report.copyEvents.isEmpty && serial.report.copyEvents.isEmpty)
        #expect(serialAudit.snapshot.finalPixelAllocations == 0 && parallelAudit.snapshot.finalPixelAllocations == 0)
        #expect(serialAudit.snapshot.workingPlaneAllocations == parallelAudit.snapshot.workingPlaneAllocations)
        #expect(serialAudit.snapshot.workingPlaneBytes == parallelAudit.snapshot.workingPlaneBytes)
        let decoded = try await Decoder().decode(parallel.data)
        let original = try source.storage.withUnsafeBytes { Data($0) }
        #expect(try decoded.image.storage.withUnsafeBytes { Data($0) } == original)
    }

    @Test func cancellationInsideWorkerIsObservedAndAllWorkersJoin() throws {
        let cancellation = ScalarOperationCancellation()
        let context = ScalarEncodingWork(budget: try budget(workers: 8, cancellation: cancellation), writerByteLimit: 1024)
        let counts = Mutex(Counts())
        #expect(throws: CancellationError.self) {
            try ScalarEncodingWork.$current.withValue(context) {
                _ = try parallelMap(20) { index -> Int in
                    counts.withLock { $0.active += 1 }
                    defer { counts.withLock { $0.active -= 1; $0.completed += 1 } }
                    // Cancel from inside an entered synchronous worker. No
                    // scheduling delay or image-size assumption is involved.
                    cancellation.cancel()
                    do { try context.checkpoint(); Issue.record("Worker ignored cancellation") }
                    catch is CancellationError {}
                    return index
                }
            }
        }
        let settled = counts.withLock { $0 }
        #expect(settled.completed >= 1 && settled.active == 0)
    }

    @Test func publicCancellationAfterWorkersJoinPreventsPublication() async throws {
        let source = try image(width: 1025, height: 7), audit = ScalarStorageAudit()
        let reachedCompletion = Mutex(false)
        let completionAudit = Mutex<ScalarStorageAudit.Snapshot?>(nil)
        let task = Task {
            try await ScalarStorageAudit.$current.withValue(audit) {
                try await Encoder().encode(source, options: .init(
                    resourceLimits: .init(maximumWorkers: 8), progress: { update in
                        if update.phase == .completed {
                            reachedCompletion.withLock { $0 = true }
                            completionAudit.withLock { $0 = audit.snapshot }
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    }))
            }
        }
        do { _ = try await task.value; Issue.record("Cancelled encoder returned a result") }
        catch is CancellationError {}
        #expect(reachedCompletion.withLock { $0 })
        let completed = try #require(completionAudit.withLock { $0 })
        // Observe real entered workers and their join before publication, rather
        // than using temporary rectangle allocations as an indirect proxy.
        #expect(completed.workerJobsStarted > 0)
        #expect(completed.workerJobsCompleted == completed.workerJobsStarted)
        #expect(completed.activeWorkerJobs == 0)
        // Residual trials borrow this one input plane instead of copying tiles.
        #expect(completed.workingPlaneAllocations == 1)
        #expect(completed.workingPlaneBytes == 1025 * 7 * MemoryLayout<Int32>.stride)
        // Cancellation must prevent publication without affecting source ownership.
        #expect(try source.storage.withUnsafeBytes { $0.count } == source.descriptor.requiredByteCount)
    }

    @Test func concurrentEncodesShareTheImmutableSource() async throws {
        let source = try image(width: 1025, height: 7, channels: 4), encoder = try Encoder()
        let options = EncodeOptions(resourceLimits: try .init(maximumWorkers: 2))
        let expected = try await encoder.encode(source, options: options).data
        let outputs = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<4 { group.addTask { try await encoder.encode(source, options: options).data } }
            var data: [Data] = []
            for try await item in group { data.append(item) }
            return data
        }
        #expect(outputs.count == 4 && outputs.allSatisfy { $0 == expected })
    }
}
