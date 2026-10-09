// SPDX-License-Identifier: Apache-2.0
// Variable-length count algorithm adapted from JXLSwift
// 57e81cb9e2411d1efac435b429a306a031744c1e, Brotli/BrotliBitReader.swift.
import Foundation

/// RFC 7932 LSB-first reader. Retains the input owner and uses relative offsets;
/// no pointer escapes and no full-input byte-array copy is made.
struct BrotliReader {
    let data: Data
    let policy: BrotliPolicy
    private(set) var position = 0
    private var readsUntilCheckpoint = 0
    var remainingBits: Int { data.count * 8 - position }

    init(_ data: Data, budget: inout BrotliBudget) throws {
        guard data.count <= budget.policy.maximumInputBytes else { throw BrotliError.resourceLimit }
        try budget.reserve(data.count)
        self.data = data
        self.policy = budget.policy
    }

    mutating func read(bits count: Int) throws -> UInt32 {
        guard (0...32).contains(count) else { throw BrotliError.malformed("Bit width") }
        if readsUntilCheckpoint == 0 {
            try policy.checkpoint()
            readsUntilCheckpoint = 1024
        }
        readsUntilCheckpoint -= 1
        guard count <= remainingBits else { throw BrotliError.truncated }
        var result: UInt32 = 0
        var consumed = 0
        while consumed < count {
            let shift = position & 7
            let take = min(8 - shift, count - consumed)
            let byte = data[data.startIndex + (position >> 3)]
            result |= ((UInt32(byte) >> shift) & ((1 << take) - 1)) << consumed
            position += take
            consumed += take
        }
        return result
    }

    mutating func readBit() throws -> Bool { try read(bits: 1) != 0 }

    /// RFC 7932 section 9.2 block-type/tree counts: 1...256.
    mutating func readVarLenU8() throws -> Int {
        if try !readBit() { return 1 }
        let bits = Int(try read(bits: 3))
        return (1 << bits) + 1 + Int(try read(bits: bits))
    }

    mutating func alignToByte() throws {
        let count = (8 - (position & 7)) & 7
        guard try read(bits: count) == 0 else { throw BrotliError.malformed("Nonzero fill bits") }
    }

    /// Metadata is skipped without allocating or adding it to output/history.
    mutating func skipAlignedBytes(_ count: Int) throws {
        try policy.checkpoint()
        guard position & 7 == 0, count >= 0 else { throw BrotliError.malformed("Byte range") }
        guard count <= remainingBits / 8 else { throw BrotliError.truncated }
        position += count * 8
    }

    mutating func requireEnd() throws {
        try alignToByte()
        guard remainingBits == 0 else { throw BrotliError.malformed("Trailing input") }
    }
}
