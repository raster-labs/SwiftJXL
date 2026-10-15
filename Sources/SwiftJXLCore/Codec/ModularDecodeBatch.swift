// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Synchronization

/// Synchronous bounded group work. Callbacks capture immutable descriptors and
/// compressed input, own their group planes, and return owned Sendable results.
/// Caller destination pointers must never enter this helper. Every callback has
/// joined before cancellation, ordered errors or results reach the caller.
func modularDecodeBatch<T: Sendable>(count: Int, budget: ScalarOperationBudget,
                                    _ work: @Sendable (Int) throws -> T) throws -> [T] {
    guard count > 0, count <= budget.maximumWorkers else {
        throw ScalarModularError.invalidInput("Invalid decoder batch size")
    }
    let slotBytes = try ScalarOperationBudget.sum(MemoryLayout<Result<T, any Error>?>.stride, MemoryLayout<T>.stride)
    try budget.reserveWorkspace(ScalarOperationBudget.sum(128,
        ScalarOperationBudget.product(count, ScalarOperationBudget.product(slotBytes, 2))))
    let results = Mutex([Result<T, any Error>?](repeating: nil, count: count))
    let audit = ScalarStorageAudit.current
    DispatchQueue.concurrentPerform(iterations: count) { index in
        ScalarStorageAudit.$current.withValue(audit) {
            let result = Result {
                try budget.checkpoint()
                audit?.workerStarted()
                defer { audit?.workerCompleted() }
                return try work(index)
            }
            results.withLock { $0[index] = result }
        }
    }
    try budget.checkpoint()
    var output: [T] = []
    output.reserveCapacity(count)
    for slot in results.withLock({ $0 }) {
        guard let slot else { throw ScalarModularError.invalidInput("Missing decoder worker result") }
        output.append(try slot.get())
    }
    return output
}
