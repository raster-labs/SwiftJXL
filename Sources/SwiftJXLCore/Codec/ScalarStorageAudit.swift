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
    }
    private let state = Mutex(Snapshot())
    package init() {}
    package var snapshot: Snapshot { state.withLock { $0 } }
    package func finalPixels(_ bytes: Int) {
        state.withLock { $0.finalPixelAllocations += 1; $0.finalPixelBytes += bytes }
    }
    package func workingPlane(_ bytes: Int) {
        state.withLock { $0.workingPlaneAllocations += 1; $0.workingPlaneBytes += bytes }
    }
}
