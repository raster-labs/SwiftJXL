// SPDX-License-Identifier: MIT
import Synchronization

#if os(Linux)
import Foundation

/// Linux's shipped Synchronization slow paths are not visible to TSan in the
/// qualified Swift 6.2/6.4 toolchains. Use the pthread-backed Foundation lock
/// for every Linux build, so instrumented and shipped code use the same path.
///
/// Sendable proof: `value` is private and every access takes this instance's
/// non-recursive lock. The synchronous closure cannot suspend; defer releases
/// the lock on normal and throwing exits. Sending initialisation and the
/// inout-sending/result boundary preserve ownership transfers. No pointer is
/// stored or exposed by this helper. All callers retain the box while using it.
package final class PackageMutex<Value: ~Copyable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    package init(_ value: consuming sending Value) {
        self.value = value
    }

    package func withLock<Result: ~Copyable, Failure: Error>(
        _ body: (inout sending Value) throws(Failure) -> sending Result
    ) throws(Failure) -> sending Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    package func withLockIfAvailable<Result: ~Copyable, Failure: Error>(
        _ body: (inout sending Value) throws(Failure) -> sending Result
    ) throws(Failure) -> sending Result? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return try body(&value)
    }
}
#else
/// Keep the existing platform implementation and value representation on Apple.
package typealias PackageMutex<Value: ~Copyable> = Synchronization.Mutex<Value>
#endif
