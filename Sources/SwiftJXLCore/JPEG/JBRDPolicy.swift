// SPDX-License-Identifier: Apache-2.0
import Foundation

package struct JBRDPolicy: Sendable {
    package let maximumInputBytes: Int
    package let maximumPayloadBytes: Int
    package let maximumMemoryBytes: Int
    package let maximumMarkers: Int
    package let maximumEvents: Int
    package let maximumPaddingBits: Int
    package let deadline: ContinuousClock.Instant
    private let workCheckpoint: @Sendable () throws -> Void

    package init(maximumInputBytes: Int = 4 * 1024 * 1024,
                 maximumPayloadBytes: Int = 8 * 1024 * 1024,
                 maximumMemoryBytes: Int = 64 * 1024 * 1024,
                 maximumMarkers: Int = 4096, maximumEvents: Int = 65536,
                 maximumPaddingBits: Int = 1024 * 1024,
                 deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(10)),
                 checkpoint: @escaping @Sendable () throws -> Void = {}) throws {
        guard maximumInputBytes > 0, maximumPayloadBytes > 0, maximumMemoryBytes > 0,
              (1...16384).contains(maximumMarkers), (1...65536).contains(maximumEvents),
              (1...(1 << 24)).contains(maximumPaddingBits) else { throw JBRDError.resourceLimit }
        self.maximumInputBytes = maximumInputBytes; self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumMemoryBytes = maximumMemoryBytes; self.maximumMarkers = maximumMarkers
        self.maximumEvents = maximumEvents; self.maximumPaddingBits = maximumPaddingBits
        self.deadline = deadline; self.workCheckpoint = checkpoint
    }

    package func checkpoint() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw JBRDError.resourceLimit }
        try workCheckpoint()
    }
}

/// Conservative operation-local reservation; admit every variable-size vector
/// before growth. No refund masks a retained buffer or transient capacity copy.
struct JBRDBudget {
    let policy: JBRDPolicy
    private(set) var reserved = 0
    private(set) var payload = 0
    private var events = 0

    init(policy: JBRDPolicy) { self.policy = policy }

    mutating func reserve(_ count: Int, stride: Int) throws {
        try policy.checkpoint()
        guard count >= 0, stride > 0, count <= (policy.maximumMemoryBytes - reserved) / stride else {
            throw JBRDError.resourceLimit
        }
        reserved += count * stride
    }

    mutating func reservePayload(_ count: Int) throws {
        guard count >= 0, count <= policy.maximumPayloadBytes - payload else { throw JBRDError.resourceLimit }
        try reserve(count, stride: 4)
        payload += count
    }

    mutating func reserveEvents(_ count: Int) throws {
        guard count >= 0, count <= policy.maximumEvents - events else { throw JBRDError.resourceLimit }
        try reserve(count, stride: 32)
        events += count
    }
}

package struct JBRDParsedBundle: Sendable {
    /// APP/COM/inter-marker/tail Data holds admitted sizes until Brotli and
    /// external metadata are validated and populated by the next stage.
    package let box: JBRDBox
    package let brotliRange: Range<Int>
    package let expectedBrotliBytes: Int
    package let reservedBytes: Int
}
