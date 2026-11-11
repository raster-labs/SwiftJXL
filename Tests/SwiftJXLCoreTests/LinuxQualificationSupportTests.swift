// SPDX-License-Identifier: MIT
#if os(Linux)
import Dispatch
import Foundation
import Glibc
import SwiftJXLCore
import Testing

struct LinuxQualificationSupportTests {
    private struct State: Sendable { var count = 0; var doubled = 0 }
    private enum Failure: Error { case deliberate }
    private final class Token: Sendable {
        let releases: PackageMutex<Int>
        init(_ releases: PackageMutex<Int>) { self.releases = releases }
        deinit { releases.withLock { $0 += 1 } }
    }
    private struct NoncopyableOwner: ~Copyable, Sendable { let token: Token }

    @Test func lockedValueSerialisesWritersAndConcurrentReaders() {
        let value = PackageMutex(State())
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for _ in 0..<1000 {
                if worker % 2 == 0 {
                    value.withLock { $0.count += 1; $0.doubled = $0.count * 2 }
                } else {
                    let snapshot = value.withLock { $0 }
                    #expect(snapshot.doubled == snapshot.count * 2)
                }
            }
        }
        #expect(value.withLock { $0.count } == 4000)
    }

    @Test func lockedValueUnlocksAfterTypedThrow() throws {
        let value = PackageMutex(0)
        do {
            try value.withLock { state throws(Failure) -> Void in
                state = 7
                throw .deliberate
            }
        } catch Failure.deliberate {}
        // Another thread must acquire the same lock after the throwing borrow.
        DispatchQueue.concurrentPerform(iterations: 4) { _ in value.withLock { $0 += 1 } }
        #expect(value.withLock { $0 } == 11)
        value.withLock { _ in
            #expect(value.withLockIfAvailable { $0 } == nil)
        }
        do {
            _ = try value.withLockIfAvailable { state throws(Failure) -> Void in
                state = 12
                throw .deliberate
            }
        } catch Failure.deliberate {}
        #expect(value.withLockIfAvailable { $0 } == 12)
    }

    @Test func lockedValueRetainsAndReleasesNoncopyableOwner() {
        let releases = PackageMutex(0)
        weak var observed: Token?
        do {
            let token = Token(releases)
            observed = token
            let value = PackageMutex(NoncopyableOwner(token: token))
            value.withLock { #expect($0.token === observed) }
            withExtendedLifetime(value) { #expect(observed != nil && releases.withLock { $0 } == 0) }
        }
        #expect(observed == nil && releases.withLock { $0 } == 1)
    }

    private func process(_ executable: String, _ arguments: [String],
                         _ body: (Process, URL) throws -> Void) throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let configuration = Process()
        configuration.executableURL = URL(fileURLWithPath: executable)
        configuration.arguments = arguments
        configuration.standardOutput = handle
        configuration.standardError = handle
        try body(configuration, log)
    }

    @Test func oraclePassesLiteralArgumentsAndPreservesNonzeroExit() throws {
        let literal = "$(printf unsafe); spaced argument"
        try process("/usr/bin/printf", ["%s", literal]) { child, log in
            let status = try runLinuxOracle(child)
            let output = try String(contentsOf: log, encoding: .utf8)
            #expect(status == 0)
            #expect(output == literal)
        }
        try process("/bin/false", []) { child, _ in
            let status = try runLinuxOracle(child)
            #expect(status == 1)
        }
    }

    @Test func oracleTimeoutKillsAndReapsOwnedChild() throws {
        try process("/bin/sleep", ["10"]) { child, _ in
            let started = ContinuousClock.now
            do {
                _ = try runLinuxOracle(child, timeout: .milliseconds(20))
                Issue.record("Timeout was not reported")
            } catch LinuxOracleProcessError.timedOut(let pid) {
                var status: Int32 = 0
                #expect(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD)
                #expect(ContinuousClock.now - started < .seconds(2))
            }
        }
    }

    @Test func oracleRejectsMissingExecutableAndEmbeddedNUL() throws {
        try process("/swiftjxl-missing-oracle", []) { child, _ in
            #expect(throws: LinuxOracleProcessError.self) { try runLinuxOracle(child) }
        }
        try process("/bin/true", ["bad\0argument"]) { child, _ in
            #expect(throws: LinuxOracleProcessError.self) { try runLinuxOracle(child) }
        }
    }
}
#endif
