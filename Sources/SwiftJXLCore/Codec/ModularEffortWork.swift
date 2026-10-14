// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Uniform indices floor(i * population / count), without overflowing that
/// product. The learner sees every sample up to the cap and exactly the cap
/// above it; the sequence itself allocates no sample-index array.
struct ModularLearningSamples: Sequence, Sendable {
    static let maximumCount = 256_000
    let count: Int
    private let step: Int
    private let remainder: Int

    init(population: Int) throws {
        guard population > 0 else {
            throw ScalarModularError.invalidInput("Invalid Modular learning population")
        }
        count = Swift.min(population, Self.maximumCount)
        step = population / count
        remainder = population % count
    }

    func makeIterator() -> Iterator {
        Iterator(remaining: count, count: count, step: step, remainder: remainder)
    }

    struct Iterator: IteratorProtocol {
        fileprivate var remaining: Int
        fileprivate let count: Int
        fileprivate let step: Int
        fileprivate let remainder: Int
        private var index = 0
        private var carry = 0

        fileprivate init(remaining: Int, count: Int, step: Int, remainder: Int) {
            self.remaining = remaining
            self.count = count
            self.step = step
            self.remainder = remainder
        }

        mutating func next() -> Int? {
            guard remaining > 0 else { return nil }
            let value = index
            remaining -= 1
            if remaining > 0 {
                index += step
                carry += remainder // Less than 2 * maximumCount.
                if carry >= count { index += 1; carry -= count }
            }
            return value
        }
    }
}

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
