import Dispatch
import Foundation
// Prototype only, outside package. Every value access uses this lock, all
// borrows end before unlock, and sending preserves transfer at the boundary.
final class LockedValue<Value: ~Copyable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: consuming sending Value) { self.value = value }
    func withLock<Result: ~Copyable, Failure: Error>(
        _ body: (inout sending Value) throws(Failure) -> sending Result
    ) throws(Failure) -> sending Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
enum ProbeFailure: Error { case deliberate }
func run() throws {
    let count = LockedValue(0)
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
        for _ in 0..<10000 { count.withLock { $0 += 1 } }
    }
    precondition(count.withLock { $0 } == 80000)
    do {
        try count.withLock { _ throws(ProbeFailure) -> Void in throw .deliberate }
    } catch ProbeFailure.deliberate {}
    precondition(count.withLock { $0 } == 80000)
    print("locked-value-count-and-throw-ok")
}
try run()
