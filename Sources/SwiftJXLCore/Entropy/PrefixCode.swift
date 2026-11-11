// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift 57e81cb9e2411d1efac435b429a306a031744c1e, Sources/JXLSwift/Entropy/PrefixCode.swift.
// PrefixCode — canonical-Huffman alphabet codec used as one of the two
// entropy-coder choices in JPEG XL (the other being rANS).
//
// ISO/IEC 18181-1 §C.6.2. JXL prefix codes are standard canonical
// Huffman codes built from a per-symbol "code length" array `lengths`:
//   - lengths[s] == 0  means symbol s does not appear in the alphabet.
//   - lengths[s]  > 0  is the bit length of the codeword for s.
//
// The codewords are assigned canonically: sort symbols first by length
// ascending, then by symbol index ascending; then assign sequential
// codewords starting from 0.
//
// Maximum code length per the spec is 15 bits (small enough that an
// O(2^15) decoding LUT is feasible; we use that approach).

import Foundation

package enum PrefixCodeError: Error, Sendable, Equatable {
    case invalidLengths(String)
    case oversubscribed(maxBits: Int, sumOfWeights: Int)
    case undersubscribed(maxBits: Int, sumOfWeights: Int)
    case missingSymbol(Int)
    case bitstream(BitstreamError)
}

/// Canonical-Huffman table built from a per-symbol code-length array.
/// Provides O(1) decoding via a flat lookup table indexed by the next
/// `maxLength` bits of the bitstream, and O(1) encoding via a per-
/// symbol (codeword, length) pair.
package struct PrefixCodeTable: Sendable {
    /// Maximum code length per JXL spec.
    package static let maxBits: Int = 15

    /// `codeword[s]` = the bits of symbol `s`'s codeword, MSB-first, in
    /// the lower `length[s]` bits. Zero when `length[s] == 0`.
    package let codewords: [UInt32]
    /// Bit-reversed codewords (`reverseBits(codewords[s], count: Int(lengths[s]))`)
    /// ready for LSB-first `BitWriter.write(bits:value:)`.
    package let reversedCodewords: [UInt32]
    /// `lengths[s]` = bit length of symbol `s`'s codeword, 0 if absent.
    package let lengths: [UInt8]
    /// Effective alphabet size (length of `lengths`).
    package var alphabetSize: Int { lengths.count }
    /// Maximum length actually used. ≤ `maxBits`.
    package let usedMaxLength: Int
    /// Bitmask `(1 << usedMaxLength) - 1`.
    package let usedMaxMask: UInt64
    /// True when at least one symbol has a non-zero code length.
    package let hasNonZeroLengths: Bool
    /// Default symbol for degenerate 0-bit tables (`usedMaxLength == 0`).
    package let singleSymbol: Int

    /// LSB-first decoding LUT of size `1 << usedMaxLength`.
    /// Indexed directly by the low `usedMaxLength` bits of `BitReader.bitBuf`.
    /// Each entry packs `symbol | (UInt32(length) << 16)`.
    package let lsbDecodeLUT: [UInt32]

    /// Build a prefix code from a per-symbol code-length array.
    /// Validates Kraft's inequality: ∑ 2^(maxBits - lengths[s]) must
    /// equal exactly 2^maxBits when there are ≥ 2 symbols. (A single
    /// symbol with length 0 is a degenerate "always emit symbol 0"
    /// case and is allowed.)
    package init(lengths: [UInt8]) throws {
        if lengths.isEmpty {
            throw PrefixCodeError.invalidLengths("empty lengths array")
        }
        var nonZeroCount = 0
        var firstNonZero = -1
        for i in 0..<lengths.count {
            let l = lengths[i]
            if l > UInt8(Self.maxBits) {
                throw PrefixCodeError.invalidLengths(
                    "symbol \(i) has length \(l) > maxBits (\(Self.maxBits))"
                )
            }
            if l > 0 {
                nonZeroCount &+= 1
                if firstNonZero < 0 { firstNonZero = i }
            }
        }

        // Single-symbol degenerate case: zero-length code, always emits
        // the lone symbol regardless of bitstream.
        if nonZeroCount <= 1 {
            // Zero-length codewords for everyone, decode LUT empty.
            let zeros = [UInt32](repeating: 0, count: lengths.count)
            self.codewords = zeros
            self.reversedCodewords = zeros
            self.lengths = lengths
            self.usedMaxLength = 0
            self.usedMaxMask = 0
            self.hasNonZeroLengths = nonZeroCount > 0
            self.singleSymbol = firstNonZero >= 0 ? firstNonZero : 0
            self.lsbDecodeLUT = []
            return
        }

        // Verify Kraft's inequality.
        var sumOfWeights = 0
        for l in lengths where l > 0 {
            sumOfWeights &+= 1 &<< (Self.maxBits &- Int(l))
        }
        let kraftLimit = 1 << Self.maxBits
        if sumOfWeights > kraftLimit {
            throw PrefixCodeError.oversubscribed(maxBits: Self.maxBits, sumOfWeights: sumOfWeights)
        }
        if sumOfWeights < kraftLimit {
            throw PrefixCodeError.undersubscribed(maxBits: Self.maxBits, sumOfWeights: sumOfWeights)
        }

        // Canonical Huffman assignment:
        //   1. Sort symbols by (length asc, symbol index asc).
        //   2. Assign sequential codewords; when length increases, shift
        //      the next codeword left to fill the new bit positions.
        var sortedSymbols = [Int]()
        sortedSymbols.reserveCapacity(nonZeroCount)
        for len in 1...UInt8(Self.maxBits) {
            for sym in 0..<lengths.count where lengths[sym] == len {
                sortedSymbols.append(sym)
            }
        }

        var codewords = [UInt32](repeating: 0, count: lengths.count)
        var reversedCodewords = [UInt32](repeating: 0, count: lengths.count)
        var code: UInt32 = 0
        var prevLen: UInt8 = lengths[sortedSymbols[0]]
        var maxLen: UInt8 = 0
        for sym in sortedSymbols {
            let l = lengths[sym]
            if l > prevLen {
                code <<= UInt32(l - prevLen)
                prevLen = l
            }
            codewords[sym] = code
            reversedCodewords[sym] = reverseBits(code, count: Int(l))
            if l > maxLen { maxLen = l }
            code += 1
        }
        self.codewords = codewords
        self.reversedCodewords = reversedCodewords
        self.lengths = lengths
        self.usedMaxLength = Int(maxLen)
        self.usedMaxMask = (UInt64(1) &<< UInt64(maxLen)) &- 1
        self.hasNonZeroLengths = true
        self.singleSymbol = firstNonZero >= 0 ? firstNonZero : 0

        // Build the LSB-first decoding LUT.
        let lutSize = 1 << Int(maxLen)
        var lsbLut = [UInt32](repeating: UInt32.max, count: lutSize)
        lsbLut.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for sym in sortedSymbols {
                let l = Int(lengths[sym])
                let revCw = Int(reversedCodewords[sym])
                let packed = UInt32(sym) | (UInt32(l) &<< 16)
                let step = 1 &<< l
                var idx = revCw
                while idx < lutSize {
                    base[idx] = packed
                    idx &+= step
                }
            }
        }
        self.lsbDecodeLUT = lsbLut
    }

    /// Emit a symbol's codeword to the bit writer. The codeword is
    /// written MSB-first — i.e. the high bit of `codewords[s]` goes
    /// into the bitstream first. Note: `BitWriter` itself is LSB-first
    /// within bytes, so we use `reversedCodewords[symbol]`.
    @inline(__always)
    package func encode(_ symbol: Int, to w: inout BitWriter) throws {
        guard symbol >= 0 && symbol < lengths.count else {
            throw PrefixCodeError.missingSymbol(symbol)
        }
        let l = Int(lengths[symbol])
        if l == 0 {
            if hasNonZeroLengths {
                throw PrefixCodeError.missingSymbol(symbol)
            }
            return
        }
        w.write(bits: l, value: reversedCodewords[symbol])
    }

    /// Decode a single symbol from `r`. Reads up to `usedMaxLength` bits
    /// (peek N, look up symbol, consume only the codeword length).
    @inline(__always)
    package func decode(from r: inout BitReader) throws -> Int {
        if usedMaxLength == 0 {
            return singleSymbol
        }
        let need = usedMaxLength
        if r.bitCount < need {
            r.refill()
        }
        if r.bitCount >= need {
            let raw = Int(r.bitBuf & usedMaxMask)
            let entry = lsbDecodeLUT[raw]
            let consumed = Int(entry &>> 16)
            r.bitBuf &>>= UInt64(consumed)
            r.bitCount &-= consumed
            r.pos &+= consumed
            return Int(entry & 0xFFFF)
        }
        let rem = r.bitsRemaining
        guard rem >= 1 else {
            throw PrefixCodeError.bitstream(.outOfBounds(needed: 1, remaining: 0))
        }
        let take = min(need, rem)
        let raw: UInt32
        do { raw = try r.peek(bits: take) }
        catch let e as BitstreamError {
            throw PrefixCodeError.bitstream(e)
        }
        let entry = lsbDecodeLUT[Int(raw)]
        let consumed = Int(entry &>> 16)
        do { try r.skip(bits: consumed) }
        catch let e as BitstreamError {
            throw PrefixCodeError.bitstream(e)
        }
        return Int(entry & 0xFFFF)
    }
}

/// Reverse the low `count` bits of `value`. Higher bits are zero.
@inline(__always)
private func reverseBits(_ value: UInt32, count: Int) -> UInt32 {
    var v = value
    var out: UInt32 = 0
    for _ in 0..<count {
        out = (out << 1) | (v & 1)
        v >>= 1
    }
    return out
}
