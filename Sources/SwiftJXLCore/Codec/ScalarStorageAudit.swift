// SPDX-License-Identifier: Apache-2.0
import Synchronization

/// Package-only allocation instrumentation, scoped to one operation/test task.
/// Counts actual controlled allocation sites; it does not pretend to measure
/// allocator overhead or the encoder's total workspace peak.
package final class ScalarStorageAudit: Sendable {
    @TaskLocal package static var current: ScalarStorageAudit?
    package struct Snapshot: Sendable {
        package var finalPixelAllocations = 0
        package var finalPixelBytes = 0
        package var workingPlaneAllocations = 0
        package var workingPlaneBytes = 0
        package var workerJobsStarted = 0
        package var workerJobsCompleted = 0
        package var activeWorkerJobs = 0
        package var peakActiveWorkerJobs = 0
    }
    private let state = Mutex(Snapshot())
    package init() {}
    package var snapshot: Snapshot { state.withLock { $0 } }
    package func finalPixels(_ bytes: Int) {
        state.withLock { $0.finalPixelAllocations += 1; $0.finalPixelBytes += bytes }
    }
    /// Actual entered parallel callbacks, independently of allocation choices.
    /// Completion is recorded before their Result reaches the joining caller.
    package func workerStarted() {
        state.withLock {
            $0.workerJobsStarted += 1; $0.activeWorkerJobs += 1
            $0.peakActiveWorkerJobs = max($0.peakActiveWorkerJobs, $0.activeWorkerJobs)
        }
    }
    package func workerCompleted() {
        state.withLock { $0.workerJobsCompleted += 1; $0.activeWorkerJobs -= 1 }
    }
    package func workingPlane(_ bytes: Int) {
        state.withLock { $0.workingPlaneAllocations += 1; $0.workingPlaneBytes += bytes }
    }
}
