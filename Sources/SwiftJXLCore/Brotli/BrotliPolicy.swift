// SPDX-License-Identifier: Apache-2.0
import Foundation

package enum BrotliError: Error, Equatable, Sendable {
    case malformed(String)
    case truncated
    case resourceLimit
}

/// Operation limits for native JPEG reconstruction metadata. Reservations are
/// conservative workspace bounds, not measured allocator or RSS statistics.
package struct BrotliPolicy: Sendable {
    package let maximumInputBytes: Int
    package let maximumOutputBytes: Int
    package let maximumMemoryBytes: Int
    package let maximumMetaBlocks: Int
    package let deadline: ContinuousClock.Instant
    private let workCheckpoint: @Sendable () throws -> Void

    package init(maximumInputBytes: Int = 16 * 1024 * 1024,
                 maximumOutputBytes: Int = 8 * 1024 * 1024,
                 maximumMemoryBytes: Int = 64 * 1024 * 1024,
                 maximumMetaBlocks: Int = 65536,
                 deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(10)),
                 checkpoint: @escaping @Sendable () throws -> Void = {}) throws {
        guard maximumInputBytes > 0, maximumInputBytes <= Int.max / 8,
              maximumOutputBytes >= 0, maximumMemoryBytes > 0,
              (1...65536).contains(maximumMetaBlocks) else { throw BrotliError.resourceLimit }
        self.maximumInputBytes = maximumInputBytes
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumMemoryBytes = maximumMemoryBytes
        self.maximumMetaBlocks = maximumMetaBlocks
        self.deadline = deadline
        self.workCheckpoint = checkpoint
    }

    package func checkpoint() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw BrotliError.resourceLimit }
        try workCheckpoint()
    }
}

struct BrotliBudget {
    let policy: BrotliPolicy
    private(set) var reservedBytes = 0
    init(policy: BrotliPolicy) { self.policy = policy }

    mutating func reserve(_ count: Int, stride: Int = 1) throws {
        try policy.checkpoint()
        guard count >= 0, stride > 0,
              count <= (policy.maximumMemoryBytes - reservedBytes) / stride else {
            throw BrotliError.resourceLimit
        }
        reservedBytes += count * stride
    }
}
