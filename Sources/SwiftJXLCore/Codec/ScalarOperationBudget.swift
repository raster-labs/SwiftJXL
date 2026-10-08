// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization

/// Operation-local conservative allocation admission. Charges are never released:
/// transient allocations therefore cannot conceal retained allocations. Values are
/// reservation bounds, not measurements of allocator/RSS peaks.
package final class ScalarOperationBudget: Sendable {
    private struct State { var workspace = 0; var pixels = 0; var output = 0 }
    private let state = Mutex(State())
    private let retainedBytes: Int
    private let maximumWorkspaceBytes: Int
    private let maximumMemoryBytes: Int
    package let maximumDecodedBytes: Int
    package let maximumCompressedBytes: Int
    package let deadline: ContinuousClock.Instant

    package init(retainedBytes: Int, maximumWorkspaceBytes: Int,
                 maximumMemoryBytes: Int, maximumDecodedBytes: Int,
                 maximumCompressedBytes: Int, deadline: ContinuousClock.Instant) throws {
        guard retainedBytes >= 0, maximumWorkspaceBytes > 0, maximumMemoryBytes > 0,
              maximumDecodedBytes > 0, maximumCompressedBytes > 0,
              retainedBytes <= maximumMemoryBytes else { throw ScalarModularError.resourceLimit }
        self.retainedBytes = retainedBytes
        self.maximumWorkspaceBytes = maximumWorkspaceBytes
        self.maximumMemoryBytes = maximumMemoryBytes
        self.maximumDecodedBytes = maximumDecodedBytes
        self.maximumCompressedBytes = maximumCompressedBytes
        self.deadline = deadline
    }
    package func checkpoint() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ScalarModularError.resourceLimit }
    }
    package func reserveWorkspace(_ bytes: Int) throws {
        try checkpoint()
        try state.withLock { value in
            let next = try Self.sum(value.workspace, bytes)
            try validate(workspace: next, pixels: value.pixels, output: value.output)
            value.workspace = next
        }
    }
    /// Replace, rather than add, the destination reservation when a caller has
    /// padding/extra capacity. Must run before allocating or borrowing that owner.
    package func reservePixels(_ bytes: Int) throws {
        try checkpoint()
        try state.withLock { value in
            guard bytes >= 0, bytes <= maximumDecodedBytes else { throw ScalarModularError.resourceLimit }
            let next = max(value.pixels, bytes)
            try validate(workspace: value.workspace, pixels: next, output: value.output)
            value.pixels = next
        }
    }
    package func reserveOutput(_ bytes: Int) throws {
        try checkpoint()
        try state.withLock { value in
            guard bytes >= 0, bytes <= maximumCompressedBytes else { throw ScalarModularError.resourceLimit }
            let next = max(value.output, bytes)
            try validate(workspace: value.workspace, pixels: value.pixels, output: next)
            value.output = next
        }
    }
    package var reservedWorkspaceBytes: Int { state.withLock { $0.workspace } }
    private func validate(workspace: Int, pixels: Int, output: Int) throws {
        guard workspace <= maximumWorkspaceBytes,
              try Self.sum(Self.sum(retainedBytes, workspace), Self.sum(pixels, output)) <= maximumMemoryBytes
        else { throw ScalarModularError.resourceLimit }
    }
    package static func sum(_ a: Int, _ b: Int) throws -> Int {
        let (n, overflow) = a.addingReportingOverflow(b)
        guard a >= 0, b >= 0, !overflow else { throw ScalarModularError.resourceLimit }
        return n
    }
    package static func product(_ a: Int, _ b: Int) throws -> Int {
        let (n, overflow) = a.multipliedReportingOverflow(by: b)
        guard a >= 0, b >= 0, !overflow else { throw ScalarModularError.resourceLimit }
        return n
    }

    /// Effort-3, one-channel, single-group envelope; see RESOURCE_ADMISSION.md.
    /// Every input-dependent term is admitted before creating the working plane.
    package func admitEncoder(width: Int, height: Int) throws -> Int {
        let n = try Self.product(width, height)
        let outputBound = try Self.sum(Self.product(n, 6), 64 * 1024)
        let outputLimit = min(outputBound, maximumCompressedBytes)
        // Working plane (4N), two residual/symbol candidates (12N), ANS
        // pending (24N) and refill words (4N). Double for capacity/transients.
        let arrays = try Self.product(n, 88)
        let rows = try Self.product(Self.sum(width, 2), 192)
        // Section/final writers, Data copies and growth overlap: six bounds.
        let buffers = try Self.product(outputLimit, 6)
        // Fixed alphabet <= 256; two gates, prefix LUTs, ANS inversions,
        // histograms, small header writers and allocator rounding allowance.
        let tables = 4 * 1024 * 1024
        try reserveOutput(outputLimit)
        try reserveWorkspace(Self.sum(Self.sum(arrays, rows), Self.sum(buffers, tables)))
        return outputLimit
    }
}

/// Synchronous encoder scope; inherited by no detached work. No pointers or
/// owners are stored here. Writers latch overflow because their bit API does
/// not throw; the next bounded checkpoint (and publication) must throw it.
package final class ScalarEncodingWork: Sendable {
    @TaskLocal package static var current: ScalarEncodingWork?
    package let budget: ScalarOperationBudget
    package let writerByteLimit: Int
    private let overflow = Mutex(false)
    package init(budget: ScalarOperationBudget, writerByteLimit: Int) {
        self.budget = budget; self.writerByteLimit = writerByteLimit
    }
    package func admitAppend(current: Int, adding: Int) throws {
        try checkpoint()
        guard try ScalarOperationBudget.sum(current, adding) <= writerByteLimit else {
            throw ScalarModularError.resourceLimit
        }
    }
    package func rejectGrowth() { overflow.withLock { $0 = true } }
    package func checkpoint() throws {
        try budget.checkpoint()
        guard !overflow.withLock({ $0 }) else { throw ScalarModularError.resourceLimit }
    }
    package static func checkpoint() throws {
        try Task.checkCancellation()
        try current?.checkpoint()
    }
}
