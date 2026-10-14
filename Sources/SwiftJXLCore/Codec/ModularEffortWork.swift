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
    /// Cumulative component admission, including capacity/transient overlap.
    /// These bounds supplement the caller's effort-3 envelope and never release
    /// a charge while another candidate or worker may still retain its arrays.
    static func reserve(samples: Int, bytesPerSample: Int, fixed: Int = 0) throws {
        let bytes = try ScalarOperationBudget.sum(
            ScalarOperationBudget.product(samples, bytesPerSample), fixed)
        try ScalarEncodingWork.checkpoint()
        try ScalarEncodingWork.current?.budget.reserveWorkspace(bytes)
    }

    static func collectionWorkspace(width: Int, height: Int, channels: Int,
                                    groups: Int) throws -> Int {
        guard width > 0, height > 0, channels > 0, groups > 0 else {
            throw ScalarModularError.invalidInput("Invalid Modular collection geometry")
        }
        let n = try ScalarOperationBudget.product(ScalarOperationBudget.product(width, height), channels)
        // Activity: rectangles, per-rect and pooled pairs, percentile values,
        // sort scratch and flattened learning input. Tree: rectangles and the
        // six retained properties plus tokens, including append growth. Single-section tree
        // properties are charged separately by propertyWorkspace.
        let arrays = try ScalarOperationBudget.product(n, 128)
        let slots = try ScalarOperationBudget.product(groups, channels)
        let rows = try ScalarOperationBudget.product(
            ScalarOperationBudget.product(ScalarOperationBudget.sum(min(width, 512), 2), slots), 96)
        return try ScalarOperationBudget.sum(arrays,
            ScalarOperationBudget.sum(rows, ScalarOperationBudget.product(slots, 1024)))
    }

    static func learnerWorkspace(samples: Int, leaves: Int) throws -> Int {
        guard (1...ModularLearningSamples.maximumCount).contains(samples),
              (2...32).contains(leaves) else { throw ScalarModularError.resourceLimit }
        // Log table, packed/radix buffers, root indices and returned contexts:
        // 40 bytes/sample, doubled. Each of at most leaves-1 splits reserves
        // both full-capacity child index arrays (16 bytes/sample), doubled,
        // even for a maximally unbalanced sequence. Fixed space covers all
        // <=63 nodes, six-property histograms, radix counts and tree output.
        let perSample = try ScalarOperationBudget.sum(80,
            ScalarOperationBudget.product(leaves - 1, 32))
        return try ScalarOperationBudget.sum(
            ScalarOperationBudget.product(samples, perSample), 4 * 1024 * 1024)
    }

    static func reserveCost(samples: Int, contexts: Int, groups: Int) throws {
        let tables = try ScalarOperationBudget.product(contexts, 2 * 1024 * 1024)
        try reserve(samples: samples, bytesPerSample: 12, fixed:
            ScalarOperationBudget.sum(tables, ScalarOperationBudget.product(groups, 1024)))
    }

    static func reserveEmission(samples: Int, contexts: Int, groups: Int) throws {
        guard let work = ScalarEncodingWork.current else {
            try ScalarEncodingWork.checkpoint(); return
        }
        // Each group can retain its own writer/Data and ANS inversion tables.
        // Charge all groups cumulatively, irrespective of the worker ceiling.
        let tables = try ScalarOperationBudget.product(
            ScalarOperationBudget.sum(6, ScalarOperationBudget.product(contexts, groups)), 1024 * 1024)
        let buffers = try ScalarOperationBudget.product(
            ScalarOperationBudget.product(work.writerByteLimit, ScalarOperationBudget.sum(groups, 1)), 6)
        try reserve(samples: samples, bytesPerSample: 64,
                    fixed: ScalarOperationBudget.sum(tables, buffers))
    }

    /// Stable bounded runs followed by checkpointed merges. The standard
    /// library only sorts runs of at most 1,024 values; long equal/descending
    /// runs therefore cannot perform an unchecked whole-image move. Callers
    /// admit the arrays and sort scratch. Allocation/COW runtime work is not
    /// interruptible, so this is a CPU-work bound, not a real-time guarantee.
    static func sort<T>(_ values: inout [T], by less: (T, T) -> Bool,
                        checkpoint: () throws -> Void = ScalarEncodingWork.checkpoint) throws {
        try checkpoint()
        let count = values.count
        let run = 1024
        try values.withUnsafeMutableBufferPointer { buffer in
            var start = 0
            while start < count {
                try checkpoint()
                let end = start + min(run, count - start)
                var chunk = UnsafeMutableBufferPointer(rebasing: buffer[start..<end])
                chunk.sort(by: less)
                start = end
            }
        }
        guard count > run else { try checkpoint(); return }
        var scratch = values
        var width = run
        while width < count {
            try checkpoint()
            try values.withUnsafeBufferPointer { source in
                try scratch.withUnsafeMutableBufferPointer { destination in
                    var start = 0
                    while start < count {
                        let middle = start + min(width, count - start)
                        let end = middle + min(width, count - middle)
                        var left = start, right = middle
                        var blockStart = start
                        while blockStart < end {
                            try checkpoint()
                            let blockEnd = blockStart + min(run, end - blockStart)
                            for output in blockStart..<blockEnd {
                                // Choose left on equality, preserving the original
                                // order of equal properties and existing tie rules.
                                if right < end && (left == middle || less(source[right], source[left])) {
                                    destination[output] = source[right]; right += 1
                                } else {
                                    destination[output] = source[left]; left += 1
                                }
                            }
                            blockStart = blockEnd
                        }
                        start = end
                    }
                }
            }
            swap(&values, &scratch)
            width = width > count / 2 ? count : width * 2
        }
        try checkpoint()
    }

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
