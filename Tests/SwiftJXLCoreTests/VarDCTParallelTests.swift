// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct VarDCTParallelTests {
    private func budget(workers: Int, bytes: Int = 256 * 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: bytes,
            maximumMemoryBytes: bytes, maximumDecodedBytes: bytes, maximumCompressedBytes: bytes,
            deadline: .now.advanced(by: .seconds(120)), maximumWorkers: workers)
    }
    private func source(width: Int, height: Int, alpha: Bool) throws -> Image {
        let channels = alpha ? 4 : 3
        let plane = try PlaneDescriptor(width: width, height: height, components: Array(0..<channels),
            sampleStride: 2, pixelStride: channels * 2, rowBytes: width * channels * 2,
            byteCount: width * height * channels * 2)
        let descriptor = try ImageDescriptor(width: width, height: height,
            components: alpha ? [.red, .green, .blue, .alpha] : [.red, .green, .blue],
            colour: .rgb, alpha: alpha ? .straight : .absent, planes: [plane])
        return try ImageDestination.allocate(descriptor: descriptor).write { bytes in
            for y in 0..<height { for x in 0..<width { for c in 0..<channels {
                let value = (x * 173 + y * 239 + c * 11 + (x * y % 31) * 901) & 65535
                let offset = ((y * width + x) * channels + c) * 2
                bytes[offset] = UInt8(truncatingIfNeeded: value)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            } } }
        }
    }
    @Test(arguments: [false, true], [65, 127])
    func oneAndEightWorkersKeepExactStreamAcrossTilesAndPartialEdges(_ alpha: Bool, _ width: Int) async throws {
        let image = try source(width: width, height: width == 65 ? 137 : 65, alpha: alpha)
        let encoder = try Encoder(configuration: .init(mode: .lossy, codecOptions: .init(varDCT: .init(distance: 1))))
        let serialAudit = ScalarStorageAudit(), parallelAudit = ScalarStorageAudit()
        let serial = try await ScalarStorageAudit.$current.withValue(serialAudit) {
            try await encoder.encode(image, options: .init(resourceLimits: .init(maximumWorkers: 1)))
        }
        let parallel = try await ScalarStorageAudit.$current.withValue(parallelAudit) {
            try await encoder.encode(image, options: .init(resourceLimits: .init(maximumWorkers: 8)))
        }
        #expect(serial.data == parallel.data)
        #expect(serial.report.copyEvents.isEmpty && parallel.report.copyEvents.isEmpty)
        #expect(serialAudit.snapshot.workerJobsStarted == 0)
        let joined = parallelAudit.snapshot
        #expect(joined.workerJobsStarted >= 3)
        #expect(joined.workerJobsCompleted == joined.workerJobsStarted && joined.activeWorkerJobs == 0)
        #expect(joined.finalPixelAllocations == 0)
    }
    @Test(arguments: [2, 3, 8], [0, 1, 2])
    func manyTilesReuseBoundedWorkerScratchAndPreserveEveryCoefficient(_ maximumWorkers: Int, _ shape: Int) throws {
        let dimensions = [(129, 129), (17, 193), (321, 129)]
        let (width, height) = dimensions[shape]
        var planes = [[Float]]()
        for channel in 0..<3 {
            var plane = [Float](); plane.reserveCapacity(width * height)
            for y in 0..<height { for x in 0..<width {
                let value = (x * 17 + y * 29 + channel * 31 + (x * y % 43) * 11) % 257
                plane.append(Float(value) / 257)
            } }
            planes.append(plane)
        }
        let serialBudget = try budget(workers: 1)
        let serial = try VarDCTHierarchicalAnalysis.analyse(planes, width: width, height: height,
            scale: 5111, distance: 1, adaptiveQuantisation: true, budget: serialBudget)
        // Square, narrow/tall and wide/partial layouts span several tile rows.
        // The additional 256 KiB admits two more conservatively charged
        // scratch sets and bounded result slots, but not a new scratch set per
        // tile or batch, even if the allocator later recycles its memory.
        let parallelBudget = try budget(workers: maximumWorkers, bytes: serialBudget.reservedWorkspaceBytes + 256 * 1024)
        let audit = ScalarStorageAudit()
        let parallel = try ScalarStorageAudit.$current.withValue(audit) {
            try VarDCTHierarchicalAnalysis.analyse(planes, width: width, height: height,
                scale: 5111, distance: 1, adaptiveQuantisation: true, budget: parallelBudget)
        }
        #expect(parallel.strategies == serial.strategies)
        #expect(parallel.quantisation == serial.quantisation)
        #expect(parallel.dc == serial.dc && parallel.ac == serial.ac)
        #expect(parallel.transforms == serial.transforms)
        // These layouts exercise respectively three row batches, multiple
        // narrow occupancy windows, and three wide row batches.
        let expectedJobs = shape == 1 ? (maximumWorkers == 2 ? 4 : 3) : 3 * min(3, maximumWorkers)
        #expect(audit.snapshot.workerJobsStarted == expectedJobs)
        #expect(audit.snapshot.workerJobsCompleted == expectedJobs && audit.snapshot.activeWorkerJobs == 0)
        #expect((1...min(3, maximumWorkers)).contains(audit.snapshot.peakActiveWorkerJobs))
    }

    @Test func workerFailureJoinsEveryBandAndAdmissionPrecedesDispatch() throws {
        let width = 17, height = 137, audit = ScalarStorageAudit()
        var planes = [[Float]](repeating: [Float](repeating: 0.375, count: width * height), count: 3)
        planes[0][0] = .nan
        #expect(throws: VarDCTError.nonFiniteSample) {
            try ScalarStorageAudit.$current.withValue(audit) {
                _ = try VarDCTHierarchicalAnalysis.analyse(planes, width: width, height: height,
                    scale: 5111, distance: 1, adaptiveQuantisation: false, budget: budget(workers: 8))
            }
        }
        #expect(audit.snapshot.workerJobsStarted == 3)
        #expect(audit.snapshot.workerJobsCompleted == 3 && audit.snapshot.activeWorkerJobs == 0)
        // A later batch can fail after earlier coefficients were packed. No
        // partial result escapes, and every callback in that batch still joins.
        let late = ScalarStorageAudit(), side = 129
        var laterPlanes = [[Float]](repeating: [Float](repeating: 0.375, count: side * side), count: 3)
        laterPlanes[0][side * side - 1] = .nan
        #expect(throws: VarDCTError.nonFiniteSample) {
            try ScalarStorageAudit.$current.withValue(late) {
                _ = try VarDCTHierarchicalAnalysis.analyse(laterPlanes, width: side, height: side,
                    scale: 5111, distance: 1, adaptiveQuantisation: false, budget: budget(workers: 8))
            }
        }
        #expect(late.snapshot.workerJobsStarted == 9)
        #expect(late.snapshot.workerJobsCompleted == 9 && late.snapshot.activeWorkerJobs == 0)
        #expect(late.snapshot.peakActiveWorkerJobs <= 3)
        let denied = ScalarStorageAudit()
        #expect(throws: ScalarModularError.self) {
            try ScalarStorageAudit.$current.withValue(denied) {
                _ = try VarDCTHierarchicalAnalysis.analyse(planes, width: width, height: height,
                    scale: 5111, distance: 1, adaptiveQuantisation: false, budget: budget(workers: 8, bytes: 1))
            }
        }
        #expect(denied.snapshot.workerJobsStarted == 0)
    }
    @Test func cancellationAfterBandJoinPreventsPublication() async throws {
        let image = try source(width: 17, height: 137, alpha: false), audit = ScalarStorageAudit()
        let completed = Mutex<ScalarStorageAudit.Snapshot?>(nil)
        let task = Task {
            try await ScalarStorageAudit.$current.withValue(audit) {
                try await Encoder(configuration: .init(mode: .lossy, codecOptions: .init(varDCT: .init(distance: 1))))
                    .encode(image, options: .init(resourceLimits: .init(maximumWorkers: 8), progress: { update in
                        if update.phase == .completed {
                            completed.withLock { $0 = audit.snapshot }
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    }))
            }
        }
        do { _ = try await task.value; Issue.record("Cancelled VarDCT operation published a result") }
        catch is CancellationError {}
        let joined = try #require(completed.withLock { $0 })
        #expect(joined.workerJobsStarted >= 3)
        #expect(joined.workerJobsCompleted == joined.workerJobsStarted && joined.activeWorkerJobs == 0)
        #expect(try image.storage.withUnsafeBytes { $0.count } == image.descriptor.requiredByteCount)
    }
}
