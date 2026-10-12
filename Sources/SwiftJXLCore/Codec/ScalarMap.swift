// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.

import Dispatch
import Synchronization

private enum ScalarMapScope {
    @TaskLocal static var isWorker = false
}

/// Bounded synchronous encoder work. Each callback owns its local scratch and
/// shares only immutable algorithm input; no caller pixel pointer enters here.
/// All callbacks join before ordered results/errors leave this function.
/// Replaces predecessor Codec/ParallelMap.swift at 57e81cb9e2411d1efac435b429a306a031744c1e.
func parallelMap<T: Sendable>(_ count: Int, _ work: @Sendable (Int) throws -> T) throws -> [T] {
    let count = max(0, count), context = ScalarEncodingWork.current
    let workers = min(context?.budget.maximumWorkers ?? 1, count)
    guard workers > 1, !ScalarMapScope.isWorker, let context else {
        return try (0..<count).map { index in
            try ScalarEncodingWork.checkpoint()
            return try work(index)
        }
    }
    // Charge result slots, the ordered output array and capacity/COW overlap.
    // The admitted encoder envelope separately covers all worker scratch.
    let elementBytes = try ScalarOperationBudget.sum(
        MemoryLayout<Result<T, any Error>?>.stride, MemoryLayout<T>.stride)
    try context.budget.reserveWorkspace(ScalarOperationBudget.sum(128,
        ScalarOperationBudget.product(count, ScalarOperationBudget.product(elementBytes, 2))))
    let results = Mutex([Result<T, any Error>?](repeating: nil, count: count))
    let audit = ScalarStorageAudit.current
    DispatchQueue.concurrentPerform(iterations: workers) { worker in
        ScalarMapScope.$isWorker.withValue(true) {
            ScalarEncodingWork.$current.withValue(context) {
                ScalarStorageAudit.$current.withValue(audit) {
                    for index in stride(from: worker, to: count, by: workers) {
                        let result = Result {
                            try context.checkpoint()
                            return try work(index)
                        }
                        results.withLock { $0[index] = result }
                    }
                }
            }
        }
    }
    try context.checkpoint()
    var output: [T] = []
    output.reserveCapacity(count)
    for result in results.withLock({ $0 }) {
        // concurrentPerform has joined every assigned index. Keep this guard
        // rather than an input-dependent force unwrap at the result boundary.
        guard let result else { throw ScalarModularError.invalidInput("Missing encoder worker result") }
        output.append(try result.get())
    }
    return output
}
