// SPDX-License-Identifier: Apache-2.0
#if os(Linux)
import Foundation
import Glibc

enum LinuxOracleProcessError: Error {
    case invalidConfiguration
    case systemCall(String, Int32)
    case timedOut(pid_t)
}

/// Test-only shell-free oracle execution. Foundation.Process is used only as
/// configuration: its Linux run-loop implementation retains a weak-reference
/// allocation even after waitUntilExit in the qualified toolchains.
/// CString owners live through posix_spawn and are then freed. FileHandle owners
/// stay alive while spawn duplicates their descriptors; the child owns those
/// duplicates. Every successfully spawned child is joined, including failures
/// and timeout cancellation. No pointer crosses an asynchronous Swift boundary.
func runLinuxOracle(_ configuration: Process, timeout: Duration = .seconds(30)) throws -> Int32 {
    guard timeout > .zero, let executable = configuration.executableURL, executable.isFileURL,
          let output = configuration.standardOutput as? FileHandle,
          let error = configuration.standardError as? FileHandle,
          configuration.currentDirectoryURL?.standardizedFileURL.path == FileManager.default.currentDirectoryPath
    else { throw LinuxOracleProcessError.invalidConfiguration }
    let arguments = [executable.path] + (configuration.arguments ?? [])
    let environment = (configuration.environment ?? ProcessInfo.processInfo.environment)
        .sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }

    func withStrings(_ values: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Int32) throws -> Int32 {
        var owners: [UnsafeMutablePointer<CChar>?] = []
        defer { for pointer in owners { free(pointer) } }
        for value in values {
            guard !value.utf8.contains(0) else { throw LinuxOracleProcessError.invalidConfiguration }
            guard let pointer = strdup(value) else { throw LinuxOracleProcessError.systemCall("strdup", ENOMEM) }
            owners.append(pointer)
        }
        owners.append(nil)
        return try owners.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { throw LinuxOracleProcessError.invalidConfiguration }
            return try body(base)
        }
    }

    var actions = posix_spawn_file_actions_t()
    let initialise = posix_spawn_file_actions_init(&actions)
    guard initialise == 0 else { throw LinuxOracleProcessError.systemCall("file_actions_init", initialise) }
    defer { posix_spawn_file_actions_destroy(&actions) }
    for (source, destination) in [(output.fileDescriptor, STDOUT_FILENO), (error.fileDescriptor, STDERR_FILENO)] {
        let code = posix_spawn_file_actions_adddup2(&actions, source, destination)
        guard code == 0 else { throw LinuxOracleProcessError.systemCall("file_actions_adddup2", code) }
    }
    var child: pid_t = 0
    let spawned = try withExtendedLifetime((output, error)) {
        try withStrings(arguments) { argv in
            try withStrings(environment) { envp in
                executable.path.withCString { path in posix_spawn(&child, path, &actions, nil, argv, envp) }
            }
        }
    }
    guard spawned == 0 else { throw LinuxOracleProcessError.systemCall("posix_spawn", spawned) }
    var joined = false
    defer {
        if !joined {
            // SIGKILL cannot be ignored. Reap after cancellation so no child or
            // process-owned descriptor survives a failed/timed-out test.
            _ = kill(child, SIGKILL)
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(child, &status, 0) } while result == -1 && errno == EINTR
        }
    }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
        var status: Int32 = 0
        let result = waitpid(child, &status, WNOHANG)
        if result == child {
            joined = true
            let signal = status & 0x7f
            return signal == 0 ? (status >> 8) & 0xff : 128 + signal
        }
        if result == -1 && errno != EINTR {
            let failure = errno
            // An external reaper means this PID is no longer ours to signal.
            if failure == ECHILD { joined = true }
            throw LinuxOracleProcessError.systemCall("waitpid", failure)
        }
        guard ContinuousClock.now < deadline else { throw LinuxOracleProcessError.timedOut(child) }
        Thread.sleep(forTimeInterval: 0.001)
    }
}
#endif
