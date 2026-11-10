// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Literal context modes defined in IETF RFC 7932 Section 7.1.
enum BrotliContextMode: UInt8, Sendable {
    case lsb6 = 0
    case msb6 = 1
    case utf8 = 2
    case signed = 3
}

/// Context ID lookup tables and context map decoding per IETF RFC 7932 Section 7.
enum BrotliContext {
    /// Lookup table `Lut0` from IETF RFC 7932 Section 7.1 (CRC-32: `0x8e91efb7`).
    static let lut0: [UInt8] = [
         0,  0,  0,  0,  0,  0,  0,  0,  0,  4,  4,  0,  0,  4,  0,  0,
         0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
         8, 12, 16, 12, 12, 20, 12, 16, 24, 28, 12, 12, 32, 12, 36, 12,
        44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 32, 32, 24, 40, 28, 12,
        12, 48, 52, 52, 52, 48, 52, 52, 52, 48, 52, 52, 52, 52, 52, 48,
        52, 52, 52, 52, 52, 48, 52, 52, 52, 52, 52, 24, 12, 28, 12, 12,
        12, 56, 60, 60, 60, 56, 60, 60, 60, 56, 60, 60, 60, 60, 60, 56,
        60, 60, 60, 60, 60, 56, 60, 60, 60, 60, 60, 24, 12, 28, 12,  0,
         0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
         0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
         0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
         0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
         2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
         2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
         2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
         2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3
    ]

    /// Lookup table `Lut1` from IETF RFC 7932 Section 7.1 (CRC-32: `0xd01a32f4`).
    static let lut1: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1,
        1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1,
        1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, 1, 1, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
    ]

    /// Lookup table `Lut2` from IETF RFC 7932 Section 7.1 (CRC-32: `0x0dd7a0d6`).
    static let lut2: [UInt8] = [
        0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7
    ]

    /// Computes the literal context ID (`0...63`) from the two preceding uncompressed bytes (`p1` most recent, `p2` second most recent) per RFC 7932 Section 7.1.
    @inline(__always)
    static func literalContextID(mode: BrotliContextMode, p1: UInt8, p2: UInt8) -> Int {
        switch mode {
        case .lsb6:
            return Int(p1 & 0x3F)
        case .msb6:
            return Int(p1 >> 2)
        case .utf8:
            return Int(lut0[Int(p1)] | lut1[Int(p2)])
        case .signed:
            return Int((lut2[Int(p1)] << 3) | lut2[Int(p2)])
        }
    }

    /// Computes the distance context ID (`0...3`) from `copyLength` per RFC 7932 Section 7.2.
    @inline(__always)
    static func distanceContextID(copyLength: Int) -> Int {
        if copyLength <= 2 { return 0 }
        if copyLength == 3 { return 1 }
        if copyLength == 4 { return 2 }
        return 3
    }

    /// Applies the inverse move-to-front transform per RFC 7932 Section 7.3.
    static func inverseMoveToFront(_ values: inout [UInt8]) {
        var mtf = (0..<256).map(UInt8.init)
        for i in values.indices {
            let index = Int(values[i])
            let value = mtf[index]
            values[i] = value
            if index > 0 {
                for k in stride(from: index, through: 1, by: -1) {
                    mtf[k] = mtf[k - 1]
                }
                mtf[0] = value
            }
        }
    }

    /// Decodes a literal or distance context map per RFC 7932 Section 7.3.
    static func readContextMap(
        count: Int,
        treeCount: Int,
        from reader: inout BrotliReader,
        budget: inout BrotliBudget
    ) throws -> (map: [UInt8], usedMoveToFront: Bool) {
        guard count > 0, (1...256).contains(treeCount) else {
            throw BrotliError.malformed("Invalid context map dimensions")
        }
        try budget.reserve(count, stride: 1)
        if treeCount == 1 {
            return ([UInt8](repeating: 0, count: count), false)
        }
        let useRLE = try reader.readBit()
        let rleMax = useRLE ? (Int(try reader.read(bits: 4)) + 1) : 0
        let alphabetSize = treeCount + rleMax
        let prefixCode = try BrotliPrefixCode.read(
            alphabetSize: alphabetSize,
            from: &reader,
            budget: &budget
        )
        var map = [UInt8](repeating: 0, count: count)
        var index = 0
        while index < count {
            if (index & 1023) == 0 {
                try budget.policy.checkpoint()
            }
            let symbol = try prefixCode.decodeSymbol(from: &reader)
            if symbol == 0 {
                map[index] = 0
                index += 1
            } else if symbol <= rleMax {
                let extra = Int(try reader.read(bits: symbol))
                let repeatZeros = (1 << symbol) + extra
                guard repeatZeros <= count - index else {
                    throw BrotliError.malformed("Context map run length exceeds map size")
                }
                index += repeatZeros
            } else {
                let treeIndex = symbol - rleMax
                guard treeIndex < treeCount else {
                    throw BrotliError.malformed("Context map tree index out of range")
                }
                map[index] = UInt8(treeIndex)
                index += 1
            }
        }
        let imtf = try reader.readBit()
        if imtf {
            inverseMoveToFront(&map)
        }
        return (map, imtf)
    }
}
