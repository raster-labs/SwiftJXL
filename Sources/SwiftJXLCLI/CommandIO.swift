// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXL
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Synchronous, nonblocking stream I/O. Polling bounds cancellation/deadline
/// latency on pipes, including a producer that never closes standard input.
struct CommandIO {
    let deadline: ContinuousClock.Instant
    let maximumMemoryBytes: Int
    // Read scratch, report construction and small command/transaction state.
    static let overhead = 256 * 1024
    static let maximumInput = 4 * 1024 * 1024

    func checkpoint() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw CodecError(.resourceLimitExceeded, "Operation deadline exceeded.")
        }
    }
    var remainingSeconds: Double {
        let parts = ContinuousClock.now.duration(to: deadline).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
    func ready(_ fd: Int32, events: Int16) throws {
        while true {
            try checkpoint()
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, 25)
            if result < 0 {
                if errno == EINTR { continue }
                throw CodecError(.ioFailure, "Stream readiness check failed.")
            }
            if result > 0 {
                if descriptor.revents & Int16(POLLNVAL) != 0 {
                    throw CodecError(.ioFailure, "Invalid stream descriptor.")
                }
                return // HUP/ERR are resolved by the following read/write.
            }
        }
    }
    func readInput(_ path: String) throws -> Data {
        try checkpoint()
        guard maximumMemoryBytes > Self.overhead else {
            throw CodecError(.resourceLimitExceeded, "Memory limit is too small for command I/O.")
        }
        // Three payload lengths allow Data growth overlap, plus fixed scratch.
        let maximum = min(Self.maximumInput, (maximumMemoryBytes - Self.overhead) / 3)
        let fd = path == "-" ? STDIN_FILENO : open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CodecError(.ioFailure, "Cannot open input.") }
        defer { if path != "-" { _ = close(fd) } }
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw CodecError(.ioFailure, "Cannot inspect input storage.") }
        let kind = status.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFIFO) else {
            throw CodecError(.ioFailure, "Input must be a regular file or pipe.")
        }
        if kind == mode_t(S_IFREG), status.st_size > maximum {
            throw CodecError(.resourceLimitExceeded, "Input exceeds compressed or aggregate memory limits.")
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw CodecError(.ioFailure, "Cannot configure input stream.")
        }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        var data = Data()
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try ready(fd, events: Int16(POLLIN))
            // One extra byte distinguishes exact-limit EOF from an oversized stream.
            let request = min(scratch.count, maximum - data.count + 1)
            let count = scratch.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, request)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw CodecError(.ioFailure, "Input read failed.")
            }
            if count == 0 { break }
            guard count <= maximum - data.count else {
                throw CodecError(.resourceLimitExceeded, "Input exceeds compressed or aggregate memory limits.")
            }
            scratch.withUnsafeBytes { raw in data.append(contentsOf: raw.bindMemory(to: UInt8.self).prefix(count)) }
        }
        try checkpoint()
        return data
    }
    func writeBytes(_ data: Data, fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw CodecError(.ioFailure, "Cannot configure output stream.")
        }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try ready(fd, events: Int16(POLLOUT))
                let count = write(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    throw CodecError(.ioFailure, "Output I/O failure.")
                }
                guard count > 0 else { throw CodecError(.ioFailure, "Output made no progress.") }
                offset += count
            }
        }
    }
    func publish(_ data: Data, path: String, inputPath: String, overwrite: Bool) throws {
        try checkpoint()
        if path == "-" { try writeBytes(data, fd: STDOUT_FILENO); return }
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), overwrite else {
                throw CodecError(.ioFailure, "Output already exists or is not a regular file.")
            }
            var input = stat()
            let inputStatus = inputPath == "-" ? fstat(STDIN_FILENO, &input) : stat(inputPath, &input)
            if inputStatus == 0,
               input.st_dev == existing.st_dev, input.st_ino == existing.st_ino {
                throw CodecError(.ioFailure, "Input and output refer to the same file.")
            }
        } else if errno != ENOENT { throw CodecError(.ioFailure, "Cannot inspect output location.") }
        let target = URL(fileURLWithPath: path)
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".swiftjxl-report-\(UUID().uuidString).tmp").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw CodecError(.ioFailure, "Cannot create report transaction.") }
        var openFD = true
        defer {
            if openFD { _ = close(fd) }
            _ = unlink(temporary)
        }
        try writeBytes(data, fd: fd)
        guard fsync(fd) == 0 else { throw CodecError(.ioFailure, "Cannot flush report transaction.") }
        let closed = close(fd); openFD = false
        guard closed == 0 else { throw CodecError(.ioFailure, "Cannot close report transaction.") }
        try checkpoint()
        // link is an atomic no-clobber publication; rename replaces atomically
        // only with explicit overwrite. Both operate within the destination folder.
        let result = overwrite ? rename(temporary, path) : link(temporary, path)
        guard result == 0 else { throw CodecError(.ioFailure, "Cannot publish final report.") }
    }
}
