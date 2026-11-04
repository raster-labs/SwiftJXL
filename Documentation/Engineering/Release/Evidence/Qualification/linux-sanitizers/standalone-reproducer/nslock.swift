import Dispatch
import Foundation
// Every count access is synchronously protected by this instance's NSLock.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    func value() -> Int { lock.withLock { count } }
}
let counter = Counter()
DispatchQueue.concurrentPerform(iterations: 8) { _ in
    for _ in 0..<10000 { counter.increment() }
}
precondition(counter.value() == 80000)
print("nslock-count-ok")
