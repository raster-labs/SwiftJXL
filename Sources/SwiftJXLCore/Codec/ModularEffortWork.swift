// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Internal effort qualification helpers; not a complete higher-effort envelope.
enum ModularEffortWork {
    /// An unusable codec candidate may be skipped; an operation failure may not.
    static func candidate<T>(_ body: () throws -> T) throws -> T? {
        try ScalarEncodingWork.checkpoint()
        do {
            let value = try body()
            try ScalarEncodingWork.checkpoint()
            return value
        } catch {
            try rethrowPolicyFailure(error)
            return nil
        }
    }

    static func rethrowPolicyFailure(_ error: any Error) throws {
        if error is CancellationError { throw error }
        if case ScalarModularError.resourceLimit = error { throw error }
        // Writers latch growth failures; ordinary candidate errors cannot hide
        // that latch, a deadline, or a cancellation raised during candidate work.
        try ScalarEncodingWork.checkpoint()
    }

    /// Incremental, cumulative reservation for wpGreedyPerPixel only. Twice the
    /// fixed array payload permits capacity/transient overlap. WP owns 48 bytes
    /// per extended column, reserved twice for every successive channel. Fixed
    /// per-array/channel allowances cover headers and rounding. Caller planes,
    /// candidate buffers and tree learning need separate admission.
    static func propertyWorkspace(width: Int, height: Int, channels: Int, tree: Bool) throws -> Int {
        guard width > 0, height > 0, channels > 0 else {
            throw ScalarModularError.invalidInput("Invalid Modular property dimensions")
        }
        let n = try ScalarOperationBudget.product(ScalarOperationBudget.product(width, height), channels)
        let perSample = tree ? 7 * MemoryLayout<Int32>.stride + MemoryLayout<Int>.stride
                             : 2 * MemoryLayout<Int32>.stride
        let arrays = try ScalarOperationBudget.product(n, perSample * 2)
        let rows = try ScalarOperationBudget.product(
            ScalarOperationBudget.product(ScalarOperationBudget.sum(width, 2), channels), 96)
        let fixed = try ScalarOperationBudget.product(ScalarOperationBudget.sum(channels, 3), 256)
        return try ScalarOperationBudget.sum(arrays, ScalarOperationBudget.sum(rows, fixed))
    }
}
