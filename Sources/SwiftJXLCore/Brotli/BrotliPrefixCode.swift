// SPDX-License-Identifier: Apache-2.0 AND MIT
// Adapted from JXLSwift 57e81cb9e2411d1efac435b429a306a031744c1e,
// Brotli/BrotliPrefixCode.swift, including its libbrotli-derived repeat logic.
// Brotli Authors' MIT terms: Documentation/ThirdParty/brotli-LICENSE.txt.
import Foundation

/// Canonical Huffman decoding in at most 15 steps, without scanning the alphabet
/// per bit. Equal-length codes use symbol order; simple code lengths use wire order.
struct BrotliPrefixCode {
    let lengths: [UInt8]
    private let counts: [Int]
    private let firstCodes: [Int]
    private let offsets: [Int]
    private let symbols: [Int]

    init(lengths: [UInt8]) throws {
        guard (1...704).contains(lengths.count), lengths.allSatisfy({ $0 <= 15 }) else {
            throw BrotliError.malformed("Prefix alphabet/length")
        }
        self.lengths = lengths
        var counts = [Int](repeating: 0, count: 16)
        for length in lengths where length != 0 { counts[Int(length)] += 1 }
        let nonzero = counts.reduce(0, +)
        guard nonzero > 0 else { throw BrotliError.malformed("Empty prefix code") }
        var space = 32768
        for length in 1...15 { space -= counts[length] << (15 - length) }
        guard nonzero == 1 || space == 0 else { throw BrotliError.malformed("Prefix Kraft sum") }
        var first = [Int](repeating: 0, count: 16)
        var offsets = [Int](repeating: 0, count: 16)
        for length in 1...15 {
            first[length] = (first[length - 1] + counts[length - 1]) << 1
            offsets[length] = offsets[length - 1] + counts[length - 1]
        }
        var symbols = [Int](repeating: 0, count: nonzero)
        var next = offsets
        for (symbol, length) in lengths.enumerated() where length != 0 {
            symbols[next[Int(length)]] = symbol
            next[Int(length)] += 1
        }
        self.counts = counts; self.firstCodes = first
        self.offsets = offsets; self.symbols = symbols
    }

    func decode(from reader: inout BrotliReader) throws -> Int {
        _ = try reader.read(bits: 0) // zero-bit trees still have cancellation checkpoints
        if symbols.count == 1 { return symbols[0] }
        var code = 0
        for length in 1...15 {
            code = code << 1 | Int(try reader.read(bits: 1))
            let delta = code - firstCodes[length]
            if delta >= 0, delta < counts[length] { return symbols[offsets[length] + delta] }
        }
        throw BrotliError.malformed("Invalid prefix codeword")
    }

    static func read(from r: inout BrotliReader, alphabet: Int,
                     budget: inout BrotliBudget) throws -> Self {
        guard (1...704).contains(alphabet) else { throw BrotliError.malformed("Prefix alphabet") }
        // Retained lengths/symbols, transient construction arrays and two small
        // code-length codes. Charges persist across meta-blocks to bound work too.
        try budget.reserve(alphabet, stride: 24)
        try budget.reserve(4096)
        let selector = Int(try r.read(bits: 2))
        if selector == 1 {
            let count = Int(try r.read(bits: 2)) + 1
            let width = alphabet == 1 ? 0 : Int.bitWidth - (alphabet - 1).leadingZeroBitCount
            var symbols = [Int]()
            for _ in 0..<count {
                let value = Int(try r.read(bits: width))
                guard value < alphabet, !symbols.contains(value) else {
                    throw BrotliError.malformed("Simple prefix symbol")
                }
                symbols.append(value)
            }
            let codeLengths: [UInt8]
            switch count {
            case 1: codeLengths = [1] // sentinel for a zero-bit tree
            case 2: codeLengths = [1, 1]
            case 3: codeLengths = [1, 2, 2]
            default: codeLengths = try r.readBit() ? [1, 2, 3, 3] : [2, 2, 2, 2]
            }
            var lengths = [UInt8](repeating: 0, count: alphabet)
            for index in 0..<count { lengths[symbols[index]] = codeLengths[index] }
            return try Self(lengths: lengths)
        }
        let order = [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]
        let staticCode = try Self(lengths: [2, 4, 3, 2, 2, 4])
        var cl = [UInt8](repeating: 0, count: 18)
        var space = 32
        var nonzero = 0
        for index in selector..<18 {
            let length = try staticCode.decode(from: &r)
            cl[order[index]] = UInt8(length)
            if length != 0 { space -= 32 >> length; nonzero += 1 }
            guard space >= 0 else { throw BrotliError.malformed("Code-length Kraft overflow") }
            if space == 0 { break }
        }
        guard nonzero == 1 || space == 0 else { throw BrotliError.malformed("Code-length Kraft sum") }
        let lengthCode = try Self(lengths: cl)
        var lengths = [UInt8](repeating: 0, count: alphabet)
        var index = 0
        var previous = 8
        var repeatCount = 0
        var repeatLength = -1
        space = 32768
        while index < alphabet, space > 0 {
            let symbol = try lengthCode.decode(from: &r)
            if symbol < 16 {
                lengths[index] = UInt8(symbol); index += 1; repeatCount = 0
                if symbol != 0 { previous = symbol; space -= 32768 >> symbol }
            } else {
                let bits = symbol == 16 ? 2 : 3
                let length = symbol == 16 ? previous : 0
                if repeatLength != length { repeatCount = 0; repeatLength = length }
                let old = repeatCount
                // Previous accepted run is bounded by alphabet <=704, so the
                // next multiplication by 8 cannot overflow a platform Int.
                if repeatCount != 0 { repeatCount = (repeatCount - 2) << bits }
                repeatCount += Int(try r.read(bits: bits)) + 3
                let delta = repeatCount - old
                guard delta > 0, delta <= alphabet - index else {
                    throw BrotliError.malformed("Prefix repeat overflow")
                }
                for _ in 0..<delta { lengths[index] = UInt8(length); index += 1 }
                if length != 0 { space -= delta << (15 - length) }
            }
        }
        guard space == 0, lengths.filter({ $0 != 0 }).count >= 2 else {
            throw BrotliError.malformed("Complex prefix Kraft sum")
        }
        return try Self(lengths: lengths)
    }
}
