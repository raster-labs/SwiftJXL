// SPDX-License-Identifier: Apache-2.0 AND MIT
// Adapted from the Brotli decoder/insert-copy/distance algorithms in JXLSwift
// 57e81cb9e2411d1efac435b429a306a031744c1e, including libbrotli-derived tables.
// See Documentation/ThirdParty/brotli-LICENSE.txt. Format: RFC 7932 sections 4–10.
import Foundation

struct BrotliDecodeStatistics: Sendable {
    var compressedMetaBlocks = 0
    var metadataMetaBlocks = 0
    var maximumLiteralBlockTypes = 0
    var maximumCommandBlockTypes = 0
    var maximumDistanceBlockTypes = 0
    var maximumLiteralTrees = 0
    var maximumDistanceTrees = 0
    var contextModeMask = 0
    var distancePostfixMask = 0
    var dictionaryReferences = 0
    var shortDistanceMask = 0
    var blockSwitches = 0
}

struct BrotliDecodedPayload: Sendable {
    let data: Data
    let reservedBytes: Int
    let statistics: BrotliDecodeStatistics
}

package enum BrotliDecoder {
    /// Decode exactly the enclosing reconstruction header's admitted payload size.
    /// No partial output, trailing stream data, or external codec fallback.
    package static func decode(_ data: Data, expectedOutputSize: Int,
                               policy: BrotliPolicy) throws -> Data {
        try decodeWithStatistics(data, expectedOutputSize: expectedOutputSize, policy: policy).data
    }

    static func decodeWithStatistics(_ data: Data, expectedOutputSize: Int,
                                     policy: BrotliPolicy) throws -> BrotliDecodedPayload {
        var statistics = BrotliDecodeStatistics()
        guard expectedOutputSize >= 0, expectedOutputSize <= policy.maximumOutputBytes else {
            throw BrotliError.resourceLimit
        }
        var budget = BrotliBudget(policy: policy)
        var reader = try BrotliReader(data, budget: &budget)
        try budget.reserve(expectedOutputSize, stride: 3)
        // Dictionary base64 decoding, retained word/transform/context tables,
        // small command/block tables and temporary transformed words.
        try budget.reserve(1024 * 1024)
        var output = [UInt8]()
        output.reserveCapacity(expectedOutputSize)
        let windowBits = try BrotliMetaBlockReader.readWindowBits(from: &reader)
        var recentDistances = [4, 11, 15, 16] // survives meta-block boundaries
        var commands = 0
        for _ in 0..<policy.maximumMetaBlocks {
            try policy.checkpoint()
            let header = try BrotliMetaBlockReader.read(from: &reader)
            switch header.kind {
            case .empty: break
            case .metadata:
                statistics.metadataMetaBlocks += 1
                try reader.skipAlignedBytes(header.length)
            case .uncompressed, .compressed:
                guard header.length <= expectedOutputSize - output.count else {
                    throw BrotliError.malformed("Declared output overrun")
                }
                if header.kind == .uncompressed {
                    for _ in 0..<header.length { output.append(UInt8(try reader.read(bits: 8))) }
                } else {
                    try compressed(length: header.length, windowBits: windowBits,
                                   reader: &reader, output: &output, recent: &recentDistances,
                                   commands: &commands, budget: &budget, statistics: &statistics)
                }
            }
            if header.isLast {
                try reader.requireEnd()
                guard output.count == expectedOutputSize else { throw BrotliError.malformed("Output size mismatch") }
                try policy.checkpoint()
                return BrotliDecodedPayload(data: Data(output), reservedBytes: budget.reservedBytes, statistics: statistics)
            }
        }
        throw BrotliError.resourceLimit
    }

    private struct Blocks {
        let count: Int
        let typeCode: BrotliPrefixCode?
        let lengthCode: BrotliPrefixCode?
        var switches = 0
        var current = 0
        var previous = 1
        var remaining: Int

        init(reader: inout BrotliReader, budget: inout BrotliBudget) throws {
            count = try reader.readVarLenU8()
            if count == 1 {
                typeCode = nil; lengthCode = nil; remaining = Int.max
            } else {
                typeCode = try BrotliPrefixCode.read(from: &reader, alphabet: count + 2, budget: &budget)
                let code = try BrotliPrefixCode.read(from: &reader, alphabet: 26, budget: &budget)
                lengthCode = code
                remaining = try Self.length(code: code, reader: &reader)
            }
        }

        static func length(code: BrotliPrefixCode, reader: inout BrotliReader) throws -> Int {
            let bases = [1,5,9,13,17,25,33,41,49,65,81,97,113,145,177,209,241,305,369,497,753,1265,2289,4337,8433,16625]
            let extras = [2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,6,6,7,8,9,10,11,12,13,24]
            let symbol = try code.decode(from: &reader)
            guard symbol < bases.count else { throw BrotliError.malformed("Block length symbol") }
            return bases[symbol] + Int(try reader.read(bits: extras[symbol]))
        }

        mutating func next(reader: inout BrotliReader) throws -> Int {
            if count == 1 { return 0 }
            if remaining == 0 {
                switches += 1
                guard let typeCode, let lengthCode else { throw BrotliError.malformed("Missing block code") }
                let symbol = try typeCode.decode(from: &reader)
                let next: Int
                switch symbol {
                case 0: next = previous
                case 1: next = (current + 1) % count
                default: next = symbol - 2
                }
                guard next < count else { throw BrotliError.malformed("Block type") }
                previous = current; current = next
                remaining = try Self.length(code: lengthCode, reader: &reader)
            }
            remaining -= 1
            return current
        }
    }

    private static func contextMap(size: Int, reader: inout BrotliReader,
                                   budget: inout BrotliBudget) throws -> (count: Int, map: [UInt8]) {
        let trees = try reader.readVarLenU8()
        try budget.reserve(size, stride: 3)
        var map = [UInt8](repeating: 0, count: size)
        if trees == 1 { return (trees, map) }
        let runBits = try reader.readBit() ? Int(try reader.read(bits: 4)) + 1 : 0
        let code = try BrotliPrefixCode.read(from: &reader, alphabet: trees + runBits, budget: &budget)
        var index = 0
        while index < size {
            let symbol = try code.decode(from: &reader)
            if symbol == 0 { index += 1 }
            else if symbol <= runBits {
                let count = (1 << symbol) + Int(try reader.read(bits: symbol))
                guard count <= size - index else { throw BrotliError.malformed("Context repeat overrun") }
                index += count
            } else {
                map[index] = UInt8(symbol - runBits); index += 1
            }
        }
        if try reader.readBit() {
            var mtf = Array(UInt8.min...UInt8.max)
            for index in 0..<size {
                if index & 255 == 0 { try budget.policy.checkpoint() }
                let rank = Int(map[index])
                let value = mtf[rank]
                if rank > 0 { for slot in stride(from: rank, through: 1, by: -1) { mtf[slot] = mtf[slot - 1] } }
                mtf[0] = value; map[index] = value
            }
        }
        guard map.allSatisfy({ Int($0) < trees }) else { throw BrotliError.malformed("Context tree index") }
        return (trees, map)
    }

    private static let insertExtras = [0,0,0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,7,8,9,10,12,14,24]
    private static let copyExtras = [0,0,0,0,0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,7,8,9,10,24]
    private static let cells = [0,1,0,1,8,9,2,16,10,17,18]
    private static let insertBases = bases(extras: insertExtras, initial: 0)
    private static let copyBases = bases(extras: copyExtras, initial: 2)
    private static func bases(extras: [Int], initial: Int) -> [Int] {
        var result = [initial]
        for index in 0..<23 { result.append(result[index] + (1 << extras[index])) }
        return result
    }

    private static func compressed(length: Int, windowBits: Int,
                                   reader: inout BrotliReader, output: inout [UInt8],
                                   recent: inout [Int], commands: inout Int,
                                   budget: inout BrotliBudget, statistics: inout BrotliDecodeStatistics) throws {
        statistics.compressedMetaBlocks += 1
        let target = output.count + length // admitted against expectedOutputSize
        var literalBlocks = try Blocks(reader: &reader, budget: &budget)
        var commandBlocks = try Blocks(reader: &reader, budget: &budget)
        var distanceBlocks = try Blocks(reader: &reader, budget: &budget)
        let postfix = Int(try reader.read(bits: 2))
        let direct = Int(try reader.read(bits: 4)) << postfix
        let distanceAlphabet = 16 + direct + (48 << postfix)
        try budget.reserve(literalBlocks.count, stride: 8)
        var modes = [Int]()
        for _ in 0..<literalBlocks.count { modes.append(Int(try reader.read(bits: 2))) }
        let literals = try contextMap(size: literalBlocks.count * 64, reader: &reader, budget: &budget)
        let distances = try contextMap(size: distanceBlocks.count * 4, reader: &reader, budget: &budget)
        func codes(_ count: Int, _ alphabet: Int, _ r: inout BrotliReader,
                   _ b: inout BrotliBudget) throws -> [BrotliPrefixCode] {
            try b.reserve(count, stride: 512)
            var result = [BrotliPrefixCode]()
            result.reserveCapacity(count)
            for _ in 0..<count { result.append(try BrotliPrefixCode.read(from: &r, alphabet: alphabet, budget: &b)) }
            return result
        }
        statistics.maximumLiteralBlockTypes = max(statistics.maximumLiteralBlockTypes, literalBlocks.count)
        statistics.maximumCommandBlockTypes = max(statistics.maximumCommandBlockTypes, commandBlocks.count)
        statistics.maximumDistanceBlockTypes = max(statistics.maximumDistanceBlockTypes, distanceBlocks.count)
        statistics.maximumLiteralTrees = max(statistics.maximumLiteralTrees, literals.count)
        statistics.maximumDistanceTrees = max(statistics.maximumDistanceTrees, distances.count)
        for mode in modes { statistics.contextModeMask |= 1 << mode }
        statistics.distancePostfixMask |= 1 << postfix
        defer { statistics.blockSwitches += literalBlocks.switches + commandBlocks.switches + distanceBlocks.switches }
        let literalCodes = try codes(literals.count, 256, &reader, &budget)
        let commandCodes = try codes(commandBlocks.count, 704, &reader, &budget)
        let distanceCodes = try codes(distances.count, distanceAlphabet, &reader, &budget)
        while output.count < target {
            if commands & 1023 == 0 { try budget.policy.checkpoint() }
            guard commands < budget.policy.maximumCommands else { throw BrotliError.resourceLimit }
            commands += 1
            let startBit = reader.position
            let startOutput = output.count
            let commandType = try commandBlocks.next(reader: &reader)
            let symbol = try commandCodes[commandType].decode(from: &reader)
            let cell = cells[symbol >> 6]
            let insertCode = (cell & 24) | ((symbol >> 3) & 7)
            let copyCode = ((cell << 3) & 24) | (symbol & 7)
            let insert = insertBases[insertCode] + Int(try reader.read(bits: insertExtras[insertCode]))
            let copy = copyBases[copyCode] + Int(try reader.read(bits: copyExtras[copyCode]))
            guard insert <= target - output.count else { throw BrotliError.malformed("Literal overrun") }
            for _ in 0..<insert {
                let type = try literalBlocks.next(reader: &reader)
                let last = output.last ?? 0
                let before = output.count >= 2 ? output[output.count - 2] : 0
                let base = modes[type] << 9
                let context = Int(BrotliContext.table[base + Int(last)] | BrotliContext.table[base + 256 + Int(before)])
                let tree = Int(literals.map[type * 64 + context])
                output.append(UInt8(try literalCodes[tree].decode(from: &reader)))
            }
            if output.count == target { break } // copy and distance omitted for final insertion
            let distanceCode: Int
            if symbol < 128 { distanceCode = 0 }
            else {
                let type = try distanceBlocks.next(reader: &reader)
                let tree = Int(distances.map[type * 4 + min(copy - 2, 3)])
                distanceCode = try distanceCodes[tree].decode(from: &reader)
            }
            if distanceCode < 16 { statistics.shortDistanceMask |= 1 << distanceCode }
            let distance: Int
            if distanceCode < 4 { distance = recent[distanceCode] }
            else if distanceCode < 16 {
                let index = distanceCode < 10 ? 0 : 1
                let variant = (distanceCode - 4) % 6
                let delta = (variant / 2 + 1) * (variant & 1 == 0 ? -1 : 1)
                distance = recent[index] + delta
            } else if distanceCode < 16 + direct { distance = distanceCode - 15 }
            else {
                let high = (distanceCode - direct - 16) >> postfix
                let low = (distanceCode - direct - 16) & ((1 << postfix) - 1)
                let bits = (high >> 1) + 1
                let extra = Int(try reader.read(bits: bits))
                let offset = ((2 + (high & 1)) << bits) - 4
                distance = ((offset + extra) << postfix) + low + direct + 1
            }
            guard distance > 0 else { throw BrotliError.malformed("Nonpositive distance") }
            let maximumDistance = min(output.count, (1 << windowBits) - 16)
            if distance > maximumDistance {
                statistics.dictionaryReferences += 1
                guard (4...24).contains(copy) else { throw BrotliError.malformed("Dictionary word length") }
                let address = distance - maximumDistance - 1
                let bits = Int(BrotliStaticDictionary.sizeBitsByLength[copy])
                let word = address & ((1 << bits) - 1)
                let transform = address >> bits
                let offset = Int(BrotliStaticDictionary.offsetsByLength[copy]) + word * copy
                let bytes = try BrotliStaticDictionary.transformWord(wordOffset: offset, length: copy, transformIdx: transform)
                guard bytes.count <= target - output.count else { throw BrotliError.malformed("Dictionary output overrun") }
                output.append(contentsOf: bytes)
            } else {
                guard copy <= target - output.count else { throw BrotliError.malformed("Copy overrun") }
                if distanceCode != 0 {
                    recent[3] = recent[2]; recent[2] = recent[1]; recent[1] = recent[0]; recent[0] = distance
                }
                for index in 0..<copy {
                    if index & 4095 == 0 { try budget.policy.checkpoint() }
                    output.append(output[output.count - distance])
                }
            }
            guard reader.position != startBit || output.count != startOutput else {
                throw BrotliError.malformed("Command makes no progress")
            }
        }
    }
}
