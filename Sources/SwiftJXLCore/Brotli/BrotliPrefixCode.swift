// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Canonical prefix code decoder implementing IETF RFC 7932 Section 3.
struct BrotliPrefixCode: Sendable {
    private let singleSymbol: UInt16?
    private let maxBits: Int
    private let blCount: [Int]
    private let firstCode: [Int]
    private let firstSymbolOffset: [Int]
    private let sortedSymbols: [UInt16]

    /// Code-length symbol order defined in IETF RFC 7932 Section 3.5.
    private static let codeLengthCodeOrder: [Int] = [
        1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15
    ]

    /// Constructs a single-symbol zero-bit prefix code (RFC 7932 Sections 3.4 and 3.5).
    init(singleSymbol: Int) {
        self.singleSymbol = UInt16(singleSymbol)
        self.maxBits = 0
        self.blCount = []
        self.firstCode = []
        self.firstSymbolOffset = []
        self.sortedSymbols = []
    }

    /// Constructs a canonical prefix code from symbol bit lengths per RFC 7932 Section 3.2.
    init(codeLengths: [Int], maxBitsLimit: Int = 15, expectedSpace: Int = 32768) throws {
        var nonZeroCount = 0
        var onlySymbol = 0
        var maxLen = 0
        var counts = [Int](repeating: 0, count: maxBitsLimit + 1)

        for (symbol, length) in codeLengths.enumerated() where length > 0 {
            guard length <= maxBitsLimit else {
                throw BrotliError.malformed("Prefix code length exceeds maximum")
            }
            counts[length] += 1
            nonZeroCount += 1
            onlySymbol = symbol
            if length > maxLen {
                maxLen = length
            }
        }

        guard nonZeroCount > 0 else {
            throw BrotliError.malformed("Empty prefix code")
        }

        if nonZeroCount == 1 {
            self.singleSymbol = UInt16(onlySymbol)
            self.maxBits = 0
            self.blCount = []
            self.firstCode = []
            self.firstSymbolOffset = []
            self.sortedSymbols = []
            return
        }

        var space = expectedSpace
        for bits in 1...maxLen where counts[bits] > 0 {
            let weight = counts[bits] * (expectedSpace >> bits)
            space -= weight
        }
        guard space == 0 else {
            throw BrotliError.malformed("Incomplete or overfull canonical prefix code")
        }

        var first = [Int](repeating: 0, count: maxLen + 1)
        var offsets = [Int](repeating: 0, count: maxLen + 1)
        var code = 0
        var runningOffset = 0
        for bits in 1...maxLen {
            code = (code + counts[bits - 1]) << 1
            first[bits] = code
            offsets[bits] = runningOffset
            runningOffset += counts[bits]
        }

        var symbols = [UInt16](repeating: 0, count: nonZeroCount)
        var writeOffsets = offsets
        for (symbol, length) in codeLengths.enumerated() where length > 0 {
            let pos = writeOffsets[length]
            symbols[pos] = UInt16(symbol)
            writeOffsets[length] = pos + 1
        }

        self.singleSymbol = nil
        self.maxBits = maxLen
        self.blCount = counts
        self.firstCode = first
        self.firstSymbolOffset = offsets
        self.sortedSymbols = symbols
    }

    /// Reads a simple or complex prefix code from `reader` per RFC 7932 Sections 3.4 and 3.5.
    static func read(
        alphabetSize: Int,
        from reader: inout BrotliReader,
        budget: inout BrotliBudget
    ) throws -> BrotliPrefixCode {
        guard alphabetSize > 0 else {
            throw BrotliError.malformed("Invalid prefix code alphabet size")
        }
        try budget.reserve(alphabetSize, stride: 4)

        let hskip = Int(try reader.read(bits: 2))
        if hskip == 1 {
            return try readSimple(alphabetSize: alphabetSize, from: &reader)
        } else {
            return try readComplex(alphabetSize: alphabetSize, hskip: hskip, from: &reader)
        }
    }

    /// Reads a simple prefix code (1..4 symbols) per RFC 7932 Section 3.4.
    private static func readSimple(
        alphabetSize: Int,
        from reader: inout BrotliReader
    ) throws -> BrotliPrefixCode {
        let numSymbols = Int(try reader.read(bits: 2)) + 1
        let alphabetBits = alphabetSize <= 1 ? 0 : (Int.bitWidth - (alphabetSize - 1).leadingZeroBitCount)

        var symbols = [Int]()
        symbols.reserveCapacity(numSymbols)
        for _ in 0..<numSymbols {
            let sym = Int(try reader.read(bits: alphabetBits))
            guard sym < alphabetSize, !symbols.contains(sym) else {
                throw BrotliError.malformed("Invalid or duplicate symbol in simple prefix code")
            }
            symbols.append(sym)
        }

        if numSymbols == 1 {
            return BrotliPrefixCode(singleSymbol: symbols[0])
        }

        var codeLengths = [Int](repeating: 0, count: alphabetSize)
        switch numSymbols {
        case 2:
            codeLengths[symbols[0]] = 1
            codeLengths[symbols[1]] = 1
        case 3:
            codeLengths[symbols[0]] = 1
            codeLengths[symbols[1]] = 2
            codeLengths[symbols[2]] = 2
        case 4:
            let treeSelect = try reader.readBit()
            if treeSelect {
                codeLengths[symbols[0]] = 1
                codeLengths[symbols[1]] = 2
                codeLengths[symbols[2]] = 3
                codeLengths[symbols[3]] = 3
            } else {
                codeLengths[symbols[0]] = 2
                codeLengths[symbols[1]] = 2
                codeLengths[symbols[2]] = 2
                codeLengths[symbols[3]] = 2
            }
        default:
            throw BrotliError.malformed("Invalid simple prefix code symbol count")
        }

        return try BrotliPrefixCode(codeLengths: codeLengths)
    }

    /// Reads a single code-length code length (0..5) using the fixed variable-length code in RFC 7932 Section 3.5.
    private static func readCodeLengthCodeLength(from reader: inout BrotliReader) throws -> Int {
        let low2 = Int(try reader.read(bits: 2))
        switch low2 {
        case 0:
            return 0
        case 1:
            return 4
        case 2:
            return 3
        default:
            let bit2 = try reader.readBit()
            if !bit2 {
                return 2
            }
            let bit3 = try reader.readBit()
            return bit3 ? 5 : 1
        }
    }

    /// Reads a complex prefix code per RFC 7932 Section 3.5.
    private static func readComplex(
        alphabetSize: Int,
        hskip: Int,
        from reader: inout BrotliReader
    ) throws -> BrotliPrefixCode {
        var clCodeLengths = [Int](repeating: 0, count: 18)
        var clSpace = 32
        var clNonZero = 0

        for idx in hskip..<18 {
            let symbol = codeLengthCodeOrder[idx]
            let length = try readCodeLengthCodeLength(from: &reader)
            clCodeLengths[symbol] = length
            if length != 0 {
                let weight = 32 >> length
                guard clSpace >= weight else {
                    throw BrotliError.malformed("Code-length prefix code overfull")
                }
                clSpace -= weight
                clNonZero += 1
                if clSpace == 0 {
                    break
                }
            }
        }

        guard clNonZero == 1 || clSpace == 0 else {
            throw BrotliError.malformed("Invalid code-length prefix code")
        }

        let clTree = try BrotliPrefixCode(
            codeLengths: clCodeLengths,
            maxBitsLimit: 5,
            expectedSpace: 32
        )

        var codeLengths = [Int](repeating: 0, count: alphabetSize)
        var symbol = 0
        var prevCodeLen = 8
        var repeatCount = 0
        var repeatSymbol = -1
        var space = 32768
        var nonZeroSymbols = 0

        while symbol < alphabetSize && space > 0 {
            let codeLenSym = try clTree.decodeSymbol(from: &reader)
            if codeLenSym < 16 {
                repeatCount = 0
                repeatSymbol = -1
                codeLengths[symbol] = codeLenSym
                symbol += 1
                if codeLenSym != 0 {
                    prevCodeLen = codeLenSym
                    nonZeroSymbols += 1
                    let weight = 32768 >> codeLenSym
                    guard space >= weight else {
                        throw BrotliError.malformed("Complex prefix code space exceeded")
                    }
                    space -= weight
                }
            } else if codeLenSym == 16 {
                let extra = Int(try reader.read(bits: 2))
                let previousRepeat = (repeatSymbol == 16) ? repeatCount : 0
                let newRepeat: Int
                if previousRepeat > 0 {
                    newRepeat = 4 * (previousRepeat - 2) + (3 + extra)
                } else {
                    newRepeat = 3 + extra
                }
                let delta = newRepeat - previousRepeat
                guard symbol + delta <= alphabetSize else {
                    throw BrotliError.malformed("Repeat code 16 exceeds alphabet size")
                }
                let unitWeight = 32768 >> prevCodeLen
                let totalWeight = delta * unitWeight
                guard space >= totalWeight else {
                    throw BrotliError.malformed("Repeat code 16 exceeds prefix code space")
                }
                for i in 0..<delta {
                    codeLengths[symbol + i] = prevCodeLen
                }
                symbol += delta
                space -= totalWeight
                nonZeroSymbols += delta
                repeatCount = newRepeat
                repeatSymbol = 16
            } else if codeLenSym == 17 {
                let extra = Int(try reader.read(bits: 3))
                let previousRepeat = (repeatSymbol == 17) ? repeatCount : 0
                let newRepeat: Int
                if previousRepeat > 0 {
                    newRepeat = 8 * (previousRepeat - 2) + (3 + extra)
                } else {
                    newRepeat = 3 + extra
                }
                let delta = newRepeat - previousRepeat
                guard symbol + delta <= alphabetSize else {
                    throw BrotliError.malformed("Repeat code 17 exceeds alphabet size")
                }
                symbol += delta
                repeatCount = newRepeat
                repeatSymbol = 17
            } else {
                throw BrotliError.malformed("Invalid code-length symbol")
            }
        }

        guard space == 0, nonZeroSymbols >= 2 else {
            throw BrotliError.malformed("Complex prefix code did not sum to 32768")
        }

        return try BrotliPrefixCode(codeLengths: codeLengths)
    }

    /// Decodes one symbol from `reader` per RFC 7932 Section 3.2.
    @inline(__always)
    func decodeSymbol(from reader: inout BrotliReader) throws -> Int {
        if let single = singleSymbol {
            return Int(single)
        }
        var code = 0
        for bits in 1...maxBits {
            let bit = try reader.readBit() ? 1 : 0
            code = (code << 1) | bit
            let first = firstCode[bits]
            let count = blCount[bits]
            if code - first < count {
                return Int(sortedSymbols[firstSymbolOffset[bits] + (code - first)])
            }
        }
        throw BrotliError.malformed("Invalid prefix code bit sequence")
    }
}
