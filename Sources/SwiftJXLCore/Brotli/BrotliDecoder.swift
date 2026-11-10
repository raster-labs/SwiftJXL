// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Diagnostics and feature coverage counters recorded during Brotli decompression.
package struct BrotliDecodeStatistics: Sendable, Equatable {
    package var contextModeMask: Int = 0
    package var distancePostfixMask: Int = 0
    package var shortDistanceMask: Int = 0
    package var dictionaryReferences: Int = 0
    package var blockSwitches: Int = 0
    package var maximumLiteralBlockTypes: Int = 0
    package var maximumCommandBlockTypes: Int = 0
    package var maximumDistanceBlockTypes: Int = 0
    package var maximumLiteralTrees: Int = 0
    package var maximumDistanceTrees: Int = 0
    package var metadataMetaBlocks: Int = 0
    package var compressedMetaBlocks: Int = 0

    package init() {}
}

/// Decompressed Brotli payload with admitted workspace budget and coverage statistics.
package struct BrotliDecodeResult: Sendable {
    package let data: Data
    package let reservedBytes: Int
    package let statistics: BrotliDecodeStatistics
}

/// Clean-room Brotli decompressor implementing IETF RFC 7932.
package enum BrotliDecoder {
    /// Insert length extra bits for codes `0...23` (RFC 7932 Section 5).
    private static let insertExtraBits: [Int] = [
        0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3,
        4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24
    ]

    /// Insert length base values for codes `0...23` (RFC 7932 Section 5).
    private static let insertBaseLengths: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26,
        34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594
    ]

    /// Copy length extra bits for codes `0...23` (RFC 7932 Section 5).
    private static let copyExtraBits: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2,
        3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24
    ]

    /// Copy length base values for codes `0...23` (RFC 7932 Section 5).
    private static let copyBaseLengths: [Int] = [
        2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18,
        22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118
    ]

    /// Insert code range base for the 11 cells (`0...10`) of the insert-and-copy table (RFC 7932 Section 5).
    private static let cellInsertBase: [Int] = [
        0, 0, 0, 0, 8, 8, 0, 16, 8, 16, 16
    ]

    /// Copy code range base for the 11 cells (`0...10`) of the insert-and-copy table (RFC 7932 Section 5).
    private static let cellCopyBase: [Int] = [
        0, 8, 0, 8, 0, 8, 16, 0, 16, 8, 16
    ]

    /// Block count extra bits for codes `0...25` (RFC 7932 Section 6).
    private static let blockCountExtraBits: [Int] = [
        2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5,
        5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24
    ]

    /// Block count base lengths for codes `0...25` (RFC 7932 Section 6).
    private static let blockCountBaseLengths: [Int] = [
        1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113,
        145, 177, 209, 241, 305, 369, 497, 753, 1265, 2289, 4337, 8433, 16625
    ]

    /// Block-type state machine for one block category (literal, insert-and-copy, or distance) per RFC 7932 Section 6.
    private struct BlockCategoryState {
        let numBlockTypes: Int
        let typeTree: BrotliPrefixCode?
        let countTree: BrotliPrefixCode?
        var currentType: Int
        var previousType: Int
        var remainingCount: Int

        static func read(
            from reader: inout BrotliReader,
            budget: inout BrotliBudget
        ) throws -> BlockCategoryState {
            let numTypes = try reader.readVarLenU8()
            guard (1...256).contains(numTypes) else {
                throw BrotliError.malformed("Invalid block type count")
            }
            if numTypes >= 2 {
                let typeTree = try BrotliPrefixCode.read(
                    alphabetSize: numTypes + 2,
                    from: &reader,
                    budget: &budget
                )
                let countTree = try BrotliPrefixCode.read(
                    alphabetSize: 26,
                    from: &reader,
                    budget: &budget
                )
                let initialCount = try decodeBlockCount(tree: countTree, from: &reader)
                return BlockCategoryState(
                    numBlockTypes: numTypes,
                    typeTree: typeTree,
                    countTree: countTree,
                    currentType: 0,
                    previousType: 1,
                    remainingCount: initialCount
                )
            } else {
                return BlockCategoryState(
                    numBlockTypes: 1,
                    typeTree: nil,
                    countTree: nil,
                    currentType: 0,
                    previousType: 1,
                    remainingCount: 16_777_216
                )
            }
        }

        private static func decodeBlockCount(
            tree: BrotliPrefixCode,
            from reader: inout BrotliReader
        ) throws -> Int {
            let code = try tree.decodeSymbol(from: &reader)
            guard (0..<26).contains(code) else {
                throw BrotliError.malformed("Block count code out of range")
            }
            let extra = Int(try reader.read(bits: BrotliDecoder.blockCountExtraBits[code]))
            return BrotliDecoder.blockCountBaseLengths[code] + extra
        }

        mutating func step(
            from reader: inout BrotliReader,
            statistics: inout BrotliDecodeStatistics
        ) throws {
            if numBlockTypes >= 2 && remainingCount == 0 {
                guard let typeTree, let countTree else {
                    throw BrotliError.malformed("Missing block switch prefix trees")
                }
                let typeCode = try typeTree.decodeSymbol(from: &reader)
                let nextType: Int
                if typeCode == 0 {
                    nextType = previousType
                } else if typeCode == 1 {
                    nextType = (currentType + 1) % numBlockTypes
                } else {
                    nextType = typeCode - 2
                }
                guard (0..<numBlockTypes).contains(nextType) else {
                    throw BrotliError.malformed("Decoded block type out of range")
                }
                previousType = currentType
                currentType = nextType
                remainingCount = try Self.decodeBlockCount(tree: countTree, from: &reader)
                statistics.blockSwitches += 1
            }
            remainingCount -= 1
        }
    }

    /// Decompresses a Brotli stream and verifies `expectedOutputSize`.
    package static func decode(
        _ data: Data,
        expectedOutputSize: Int,
        policy: BrotliPolicy
    ) throws -> Data {
        try decodeWithStatistics(data, expectedOutputSize: expectedOutputSize, policy: policy).data
    }

    /// Decompresses a Brotli stream, returning the output `Data`, reserved workspace bytes, and coverage statistics.
    package static func decodeWithStatistics(
        _ data: Data,
        expectedOutputSize: Int,
        policy: BrotliPolicy
    ) throws -> BrotliDecodeResult {
        try policy.checkpoint()
        guard expectedOutputSize >= 0, expectedOutputSize <= policy.maximumOutputBytes else {
            throw BrotliError.resourceLimit
        }

        var budget = BrotliBudget(policy: policy)
        var reader = try BrotliReader(data, budget: &budget)
        // Reserve resident static dictionary/context allowance and output capacity.
        try budget.reserve(1024 * 1024)
        try budget.reserve(expectedOutputSize, stride: 2)

        let windowBits = try BrotliMetaBlockReader.readWindowBits(from: &reader)
        let maxBackwardWindow = (1 << windowBits) - 16

        var output = [UInt8]()
        output.reserveCapacity(expectedOutputSize)

        // Ring buffer of last 4 distances initialized to [4, 11, 15, 16] per RFC 7932 Section 4.
        var distRing0 = 4
        var distRing1 = 11
        var distRing2 = 15
        var distRing3 = 16

        var statistics = BrotliDecodeStatistics()
        var metaBlocksSeen = 0
        var commandsExecuted = 0

        while true {
            try policy.checkpoint()
            metaBlocksSeen += 1
            guard metaBlocksSeen <= policy.maximumMetaBlocks else {
                throw BrotliError.resourceLimit
            }

            let header = try BrotliMetaBlockReader.read(from: &reader)
            switch header.kind {
            case .empty:
                break

            case .metadata:
                statistics.metadataMetaBlocks += 1
                try reader.skipAlignedBytes(header.length)

            case .uncompressed:
                guard header.length <= expectedOutputSize - output.count else {
                    throw BrotliError.malformed("Uncompressed meta-block exceeds expected output size")
                }
                for i in 0..<header.length {
                    if (i & 4095) == 0 {
                        try policy.checkpoint()
                    }
                    let byte = UInt8(truncatingIfNeeded: try reader.read(bits: 8))
                    output.append(byte)
                }

            case .compressed:
                statistics.compressedMetaBlocks += 1
                let mlen = header.length
                guard mlen <= expectedOutputSize - output.count else {
                    throw BrotliError.malformed("Compressed meta-block exceeds expected output size")
                }

                var literalBlockState = try BlockCategoryState.read(from: &reader, budget: &budget)
                var commandBlockState = try BlockCategoryState.read(from: &reader, budget: &budget)
                var distanceBlockState = try BlockCategoryState.read(from: &reader, budget: &budget)

                statistics.maximumLiteralBlockTypes = max(statistics.maximumLiteralBlockTypes, literalBlockState.numBlockTypes)
                statistics.maximumCommandBlockTypes = max(statistics.maximumCommandBlockTypes, commandBlockState.numBlockTypes)
                statistics.maximumDistanceBlockTypes = max(statistics.maximumDistanceBlockTypes, distanceBlockState.numBlockTypes)

                let npostfix = Int(try reader.read(bits: 2))
                let ndirectHigh = Int(try reader.read(bits: 4))
                let ndirect = ndirectHigh << npostfix
                let postfixMask = (1 << npostfix) - 1
                statistics.distancePostfixMask |= (1 << npostfix)

                var contextModes = [BrotliContextMode]()
                contextModes.reserveCapacity(literalBlockState.numBlockTypes)
                for _ in 0..<literalBlockState.numBlockTypes {
                    let rawMode = UInt8(try reader.read(bits: 2))
                    guard let mode = BrotliContextMode(rawValue: rawMode) else {
                        throw BrotliError.malformed("Invalid literal context mode")
                    }
                    contextModes.append(mode)
                    statistics.contextModeMask |= (1 << Int(rawMode))
                }

                let numLiteralTrees = try reader.readVarLenU8()
                statistics.maximumLiteralTrees = max(statistics.maximumLiteralTrees, numLiteralTrees)
                let (literalContextMap, _) = try BrotliContext.readContextMap(
                    count: 64 * literalBlockState.numBlockTypes,
                    treeCount: numLiteralTrees,
                    from: &reader,
                    budget: &budget
                )

                let numDistanceTrees = try reader.readVarLenU8()
                statistics.maximumDistanceTrees = max(statistics.maximumDistanceTrees, numDistanceTrees)
                let (distanceContextMap, _) = try BrotliContext.readContextMap(
                    count: 4 * distanceBlockState.numBlockTypes,
                    treeCount: numDistanceTrees,
                    from: &reader,
                    budget: &budget
                )

                var literalTrees = [BrotliPrefixCode]()
                literalTrees.reserveCapacity(numLiteralTrees)
                for _ in 0..<numLiteralTrees {
                    literalTrees.append(try BrotliPrefixCode.read(alphabetSize: 256, from: &reader, budget: &budget))
                }

                var commandTrees = [BrotliPrefixCode]()
                commandTrees.reserveCapacity(commandBlockState.numBlockTypes)
                for _ in 0..<commandBlockState.numBlockTypes {
                    commandTrees.append(try BrotliPrefixCode.read(alphabetSize: 704, from: &reader, budget: &budget))
                }

                let distanceAlphabetSize = 16 + ndirect + (48 << npostfix)
                var distanceTrees = [BrotliPrefixCode]()
                distanceTrees.reserveCapacity(numDistanceTrees)
                for _ in 0..<numDistanceTrees {
                    distanceTrees.append(try BrotliPrefixCode.read(alphabetSize: distanceAlphabetSize, from: &reader, budget: &budget))
                }

                var producedInMetaBlock = 0
                while producedInMetaBlock < mlen {
                    commandsExecuted += 1
                    guard commandsExecuted <= policy.maximumCommands else {
                        throw BrotliError.resourceLimit
                    }
                    if (commandsExecuted & 63) == 1 {
                        try policy.checkpoint()
                    }

                    try commandBlockState.step(from: &reader, statistics: &statistics)
                    let iacCode = try commandTrees[commandBlockState.currentType].decodeSymbol(from: &reader)
                    guard (0..<704).contains(iacCode) else {
                        throw BrotliError.malformed("Insert-and-copy code out of range")
                    }

                    let cell = iacCode >> 6
                    let insertCode = cellInsertBase[cell] + ((iacCode >> 3) & 7)
                    let copyCode = cellCopyBase[cell] + (iacCode & 7)
                    let insertExtra = Int(try reader.read(bits: insertExtraBits[insertCode]))
                    let copyExtra = Int(try reader.read(bits: copyExtraBits[copyCode]))
                    let insertLength = insertBaseLengths[insertCode] + insertExtra
                    let copyLength = copyBaseLengths[copyCode] + copyExtra
                    let implicitDistanceZero = (iacCode < 128)

                    guard insertLength <= mlen - producedInMetaBlock else {
                        throw BrotliError.malformed("Insert length exceeds meta-block length")
                    }

                    for litIdx in 0..<insertLength {
                        if (litIdx & 1023) == 1023 {
                            try policy.checkpoint()
                        }
                        try literalBlockState.step(from: &reader, statistics: &statistics)
                        let p1: UInt8 = output.isEmpty ? 0 : output[output.count - 1]
                        let p2: UInt8 = output.count < 2 ? 0 : output[output.count - 2]
                        let mode = contextModes[literalBlockState.currentType]
                        let cidl = BrotliContext.literalContextID(mode: mode, p1: p1, p2: p2)
                        let treeIndex = Int(literalContextMap[(literalBlockState.currentType << 6) + cidl])
                        let literalByte = try literalTrees[treeIndex].decodeSymbol(from: &reader)
                        output.append(UInt8(truncatingIfNeeded: literalByte))
                    }
                    producedInMetaBlock += insertLength

                    if producedInMetaBlock == mlen {
                        break
                    }

                    let distance: Int
                    let distanceCode: Int
                    if implicitDistanceZero {
                        distanceCode = 0
                        distance = distRing0
                        statistics.shortDistanceMask |= 1
                    } else {
                        try distanceBlockState.step(from: &reader, statistics: &statistics)
                        let cidd = BrotliContext.distanceContextID(copyLength: copyLength)
                        let treeIndex = Int(distanceContextMap[(distanceBlockState.currentType << 2) + cidd])
                        distanceCode = try distanceTrees[treeIndex].decodeSymbol(from: &reader)
                        if distanceCode < 16 {
                            statistics.shortDistanceMask |= (1 << distanceCode)
                            switch distanceCode {
                            case 0: distance = distRing0
                            case 1: distance = distRing1
                            case 2: distance = distRing2
                            case 3: distance = distRing3
                            case 4: distance = distRing0 - 1
                            case 5: distance = distRing0 + 1
                            case 6: distance = distRing0 - 2
                            case 7: distance = distRing0 + 2
                            case 8: distance = distRing0 - 3
                            case 9: distance = distRing0 + 3
                            case 10: distance = distRing1 - 1
                            case 11: distance = distRing1 + 1
                            case 12: distance = distRing1 - 2
                            case 13: distance = distRing1 + 2
                            case 14: distance = distRing1 - 3
                            case 15: distance = distRing1 + 3
                            default: distance = 0
                            }
                        } else if distanceCode < 16 + ndirect {
                            distance = distanceCode - 15
                        } else {
                            let d = distanceCode - ndirect - 16
                            let ndistbits = 1 + (d >> (npostfix + 1))
                            guard (1...24).contains(ndistbits) else {
                                throw BrotliError.malformed("Distance extra bit count out of range")
                            }
                            let dextra = Int(try reader.read(bits: ndistbits))
                            let hcode = d >> npostfix
                            let lcode = d & postfixMask
                            let offset = ((2 + (hcode & 1)) << ndistbits) - 4
                            distance = ((offset + dextra) << npostfix) + lcode + ndirect + 1
                        }
                    }

                    guard distance > 0 else {
                        throw BrotliError.malformed("Resolved distance must be positive")
                    }

                    let maxAllowedDistance = min(maxBackwardWindow, output.count)
                    if distance <= maxAllowedDistance {
                        if distanceCode != 0 {
                            distRing3 = distRing2
                            distRing2 = distRing1
                            distRing1 = distRing0
                            distRing0 = distance
                        }
                        guard copyLength <= mlen - producedInMetaBlock else {
                            throw BrotliError.malformed("Copy length exceeds meta-block length")
                        }
                        let startIdx = output.count - distance
                        for copyIdx in 0..<copyLength {
                            if (copyIdx & 511) == 0 {
                                try policy.checkpoint()
                            }
                            output.append(output[startIdx + copyIdx])
                        }
                        producedInMetaBlock += copyLength
                    } else {
                        let wordID = distance - (maxAllowedDistance + 1)
                        let wordBytes = try BrotliStaticDictionary.resolveWord(length: copyLength, wordID: wordID)
                        guard wordBytes.count <= mlen - producedInMetaBlock else {
                            throw BrotliError.malformed("Dictionary word exceeds meta-block length")
                        }
                        output.append(contentsOf: wordBytes)
                        producedInMetaBlock += wordBytes.count
                        statistics.dictionaryReferences += 1
                    }
                }
            }

            if header.isLast {
                break
            }
        }

        try reader.requireEnd()
        guard output.count == expectedOutputSize else {
            throw BrotliError.malformed("Brotli output size does not match expected size")
        }

        return BrotliDecodeResult(
            data: Data(output),
            reservedBytes: budget.reservedBytes,
            statistics: statistics
        )
    }
}
