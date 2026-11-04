import Dispatch
import Synchronization
func run() {
    let count = Mutex(0)
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
        for _ in 0..<10000 { count.withLock { $0 += 1 } }
    }
    precondition(count.withLock { $0 } == 80000)
    print("mutex-count-ok")
}
run()
