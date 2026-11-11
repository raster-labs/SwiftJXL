// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift JPEGBitReader/JPEGHuffmanTable/JPEGBlockDecoder at
// 57e81cb9e2411d1efac435b429a306a031744c1e. T.81 C.2, F.1.2 and F.2.2.
import Foundation

package enum JPEGEntropyError: Error, Sendable, Equatable {
    case malformed
    case unsupported
    case resourceLimit
}

package struct JPEGEntropyPadding: Sendable, Equatable {
    package let offset: Int
    package let bitCount: Int
    package let bits: UInt8
}

/// No lookahead across restart boundaries, no entropy-buffer copy. The owning
/// Data is retained and all positions are relative to its first byte.
package struct JPEGEntropyReader {
    private let data: Data
    private let end: Int
    private var position: Int
    private var remaining = 0
    private var current: UInt8 = 0
    private var nextCheckpoint = 0
    private let checkpoint: @Sendable () throws -> Void

    package init(data: Data, range: Range<Int>, checkpoint: @escaping @Sendable () throws -> Void) throws {
        guard range.lowerBound >= 0, range.upperBound <= data.count else { throw JPEGEntropyError.malformed }
        self.data = data; self.position = range.lowerBound; self.end = range.upperBound
        self.checkpoint = checkpoint
    }

    @inline(__always)
    private func byte(_ n: Int) -> UInt8 { data[data.startIndex + n] }

    @inline(__always)
    private mutating func checkWork() throws {
        if position >= nextCheckpoint {
            try checkpoint()
            nextCheckpoint = position + min(4096, end - position)
        }
    }

    @inline(__always)
    fileprivate mutating func refillByte() throws {
        guard position < end else { throw JPEGEntropyError.malformed }
        try checkWork()
        current = byte(position); position += 1
        if current == 0xff {
            guard position < end, byte(position) == 0 else { throw JPEGEntropyError.malformed }
            position += 1
        }
        remaining = 8
    }

    @inline(__always)
    package mutating func bit() throws -> Int {
        if remaining == 0 {
            try refillByte()
        }
        remaining -= 1
        return Int((current >> remaining) & 1)
    }

    @inline(__always)
    package mutating func bits(_ count: Int) throws -> Int {
        guard (0...16).contains(count) else { throw JPEGEntropyError.malformed }
        var need = count
        var value = 0
        while need > 0 {
            if remaining == 0 {
                try refillByte()
            }
            let take = min(need, remaining)
            remaining -= take
            let mask = (1 << take) - 1
            value = (value << take) | ((Int(current) >> remaining) & mask)
            need -= take
        }
        return value
    }

    @inline(__always)
    package mutating func magnitude(_ count: Int) throws -> Int32 {
        if count == 0 { return 0 }
        guard (1...15).contains(count) else { throw JPEGEntropyError.malformed }
        let value = try bits(count)
        return Int32(value >= 1 << (count - 1) ? value : value - ((1 << count) - 1))
    }

    @inline(__always)
    fileprivate mutating func decodeSymbol(
        fastLUT: [UInt16],
        firstCode: [Int],
        counts: [Int],
        firstSymbol: [Int],
        symbols: [UInt8]
    ) throws -> UInt8 {
        if remaining == 0 {
            try refillByte()
        }
        let hiLen = remaining
        let hiMask = (1 << hiLen) - 1
        let hiBits = Int(current) & hiMask
        let idx = hiBits << (8 - hiLen)
        let entry = fastLUT[idx]
        let len = Int(entry >> 8)
        if len > 0 && len <= hiLen {
            remaining = hiLen - len
            return UInt8(truncatingIfNeeded: entry)
        }
        var code: Int
        if hiLen == 8 {
            code = hiBits
            remaining = 0
        } else {
            remaining = 0
            try refillByte()
            let code8 = idx | Int(current >> hiLen)
            let entry2 = fastLUT[code8]
            let len2 = Int(entry2 >> 8)
            if len2 > 0 {
                remaining = 8 - (len2 - hiLen)
                return UInt8(truncatingIfNeeded: entry2)
            }
            code = code8
            remaining = hiLen
        }
        for i in 8..<16 {
            code = code * 2 + (try bit())
            let offset = code - firstCode[i]
            if offset >= 0 && offset < counts[i] { return symbols[firstSymbol[i] + offset] }
        }
        throw JPEGEntropyError.malformed
    }

    private mutating func padding() -> JPEGEntropyPadding {
        let mask = (1 << remaining) - 1
        let result = JPEGEntropyPadding(offset: position, bitCount: remaining, bits: current & UInt8(mask))
        remaining = 0
        return result
    }

    /// Restart markers are consumed only at the MCU interval, with sequence
    /// checking. Retain noncanonical padding for later reconstruction metadata.
    package mutating func restart(_ expected: UInt8) throws -> JPEGEntropyPadding {
        let result = padding()
        guard position < end, byte(position) == 0xff else { throw JPEGEntropyError.malformed }
        while position < end, byte(position) == 0xff {
            try checkWork()
            position += 1
        }
        guard position < end, byte(position) == expected else { throw JPEGEntropyError.malformed }
        position += 1
        return result
    }

    package mutating func finish() throws -> JPEGEntropyPadding {
        guard position == end else { throw JPEGEntropyError.malformed }
        return padding()
    }
}

package struct JPEGHuffmanTable: Sendable {
    private let firstCode: [Int]
    private let counts: [Int]
    private let firstSymbol: [Int]
    private let symbols: [UInt8]
    private let fastLUT: [UInt16]

    package init(counts: [Int], symbols: [UInt8]) throws {
        guard counts.count == 16, counts.allSatisfy({ (0...255).contains($0) }),
              !symbols.isEmpty, symbols.count <= 256, counts.reduce(0, +) == symbols.count else {
            throw JPEGEntropyError.malformed
        }
        var code = 0, index = 0, first: [Int] = [], offsets: [Int] = []
        var lut = [UInt16](repeating: 0, count: 256)
        for length in 1...16 {
            let n = counts[length - 1]
            // JPEG reserves the all-ones code so padding cannot be a symbol.
            guard code + n < (1 << length) else { throw JPEGEntropyError.malformed }
            first.append(code); offsets.append(index)
            if length <= 8 {
                let shift = 8 - length
                let span = 1 << shift
                for j in 0..<n {
                    let sym = UInt16(symbols[index + j])
                    let packed = (UInt16(length) << 8) | sym
                    let base = (code + j) << shift
                    for k in 0..<span {
                        lut[base + k] = packed
                    }
                }
            }
            index += n; code = (code + n) * 2
        }
        self.firstCode = first; self.firstSymbol = offsets
        self.counts = counts; self.symbols = symbols
        self.fastLUT = lut
    }

    @inline(__always)
    package func symbol(_ reader: inout JPEGEntropyReader) throws -> UInt8 {
        try reader.decodeSymbol(
            fastLUT: fastLUT,
            firstCode: firstCode,
            counts: counts,
            firstSymbol: firstSymbol,
            symbols: symbols
        )
    }
}

package enum JPEGZigZag {
    package static let order = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63
    ]
}
