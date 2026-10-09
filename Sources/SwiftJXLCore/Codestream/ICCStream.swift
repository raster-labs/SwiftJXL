// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Codestream/ICCStream.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors' ICC algorithms retain BSD-3-Clause terms.
// See Documentation/ThirdParty/libjxl-LICENSE.txt.
import Foundation

package enum ICCStreamError: Error, Sendable { case malformed }
package enum ICCStream {
    package static let headerSize = 128
    package static let numContexts = 41

    // MARK: - Command / flag constants (libjxl icc_codec_common.h)

    private static let kCommandTagUnknown = 1
    private static let kCommandTagTRC = 2
    private static let kCommandTagXYZ = 3
    private static let kCommandTagStringFirst = 4
    private static let kCommandInsert = 1
    private static let kCommandShuffle2 = 2
    private static let kCommandShuffle4 = 3
    private static let kCommandPredict = 4
    private static let kCommandXYZ = 10
    private static let kCommandTypeStartFirst = 16
    private static let kFlagBitOffset = 64
    private static let kFlagBitSize = 128

    // MARK: - Tag keywords

    private static func tag(_ s: String) -> [UInt8] { Array(s.utf8) }
    private static let kRtrcTag = tag("rTRC")
    private static let kGtrcTag = tag("gTRC")
    private static let kBtrcTag = tag("bTRC")
    private static let kRxyzTag = tag("rXYZ")
    private static let kGxyzTag = tag("gXYZ")
    private static let kBxyzTag = tag("bXYZ")
    private static let kKxyzTag = tag("kXYZ")
    private static let kWtptTag = tag("wtpt")
    private static let kBkptTag = tag("bkpt")
    private static let kLumiTag = tag("lumi")
    private static let kXyz_Tag = tag("XYZ ")

    /// Tag-name table (libjxl `kTagStrings`, 17 entries).
    private static let kTagStrings: [[UInt8]] = [
        tag("cprt"), tag("wtpt"), tag("bkpt"), tag("rXYZ"), tag("gXYZ"),
        tag("bXYZ"), tag("kXYZ"), tag("rTRC"), tag("gTRC"), tag("bTRC"),
        tag("kTRC"), tag("chad"), tag("desc"), tag("chrm"), tag("dmnd"),
        tag("dmdd"), tag("lumi"),
    ]
    /// Tag-type table (libjxl `kTypeStrings`, 8 entries).
    private static let kTypeStrings: [[UInt8]] = [
        tag("XYZ "), tag("desc"), tag("text"), tag("mluc"),
        tag("para"), tag("curv"), tag("sf32"), tag("gbd "),
    ]

    /// libjxl `kIccInitialHeaderPrediction` (128 bytes).
    private static let initialHeaderPrediction: [UInt8] = [
        0,0,0,0, 0,0,0,0, 4,0,0,0, 0x6d,0x6e,0x74,0x72,       // "mntr"
        0x52,0x47,0x42,0x20, 0x58,0x59,0x5a,0x20, 0,0,0,0, 0,0,0,0, // "RGB XYZ "
        0,0,0,0, 0x61,0x63,0x73,0x70, 0,0,0,0, 0,0,0,0,        // "acsp"
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
        0,0,0,0, 0,0,246,214, 0,1,0,0, 0,0,211,45,
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
    ]


    package static func decode(from reader: inout BitReader, maximumBytes: Int,
                               checkpoint: () throws -> Void) throws -> Data {
        try checkpoint()
        guard maximumBytes > 0, maximumBytes <= 4 * 1024 * 1024 else { throw JPEGEntropyError.resourceLimit }
        let count = try reader.readU64()
        guard count <= UInt64(maximumBytes * 4 + 1024) else { throw JPEGEntropyError.resourceLimit }
        try reader.budget?.reserveWorkspace(Int(count) * 2 + 32768)
        let header = try EntropySectionHeader.read(from: &reader, numContexts: numContexts)
        let codebook = try MultiClusterCodebook.read(from: &reader, header: header)
        var stream = TokenStreamReader(header: header, codebook: codebook)
        var bytes = [UInt8](); bytes.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            if i & 1023 == 0 { try checkpoint() }
            let context = iccANSContext(i: i, b1: i > 0 ? Int(bytes[i - 1]) : 0, b2: i > 1 ? Int(bytes[i - 2]) : 0)
            let value = try stream.readToken(context: context, from: &reader)
            guard value <= 255 else { throw ICCStreamError.malformed }
            bytes.append(UInt8(value))
        }
        try stream.finish()
        let budget = reader.budget
        return try unpredict(bytes, maximumBytes: maximumBytes,
            admit: { try budget?.reserveWorkspace($0 * 8 + 32768) }, checkpoint: checkpoint)
    }

    /// Standard header prediction plus literal insertion commands. The encoder
    /// intentionally avoids lossy profile interpretation or a private side box.
    package static func write(_ profile: Data, to writer: inout BitWriter,
                              maximumBytes: Int, checkpoint: () throws -> Void) throws {
        try checkpoint()
        guard !profile.isEmpty, maximumBytes > 0, profile.count <= min(maximumBytes, 4 * 1024 * 1024) else {
            throw JPEGEntropyError.resourceLimit
        }
        var commands: [UInt8] = []
        if profile.count > 128 {
            commands = [0, 1] // No predicted tag list; insert the complete tail.
            variable(profile.count - 128, to: &commands)
        }
        var encoded: [UInt8] = []
        encoded.reserveCapacity(profile.count + 32)
        variable(profile.count, to: &encoded); variable(commands.count, to: &encoded)
        encoded.append(contentsOf: commands)
        let source = Array(profile)
        var header = initialHeaderPrediction
        let size = UInt32(profile.count)
        for i in 0..<4 { header[i] = UInt8(truncatingIfNeeded: size >> ((3 - i) * 8)) }
        for i in 0..<min(128, profile.count) {
            iccPredictHeader(source, i, &header, i)
            encoded.append(source[i] &- header[i])
        }
        for i in 128..<max(128, profile.count) {
            if i & 1023 == 0 { try checkpoint() }
            encoded.append(source[i])
        }
        writer.writeU64(UInt64(encoded.count))
        let config = HybridUintConfig(splitExponent: 8, msbInToken: 0, lsbInToken: 0)
        let entropy = EntropySectionHeader(lz77: .disabled, contextMap: .trivial(numContexts: numContexts),
            usePrefixCode: true, logAlphaSize: 15, uintConfigs: [config])
        let codebook = MultiClusterCodebook(huffmanTables: [try PrefixCodeTable(lengths: [UInt8](repeating: 8, count: 256))],
            ansCounts: [], alphabetSizes: [256])
        try entropy.write(to: &writer, numContexts: numContexts); try codebook.write(to: &writer, header: entropy)
        let tokens = TokenStreamWriter(header: entropy, codebook: codebook)
        for i in encoded.indices {
            if i & 1023 == 0 { try checkpoint(); try ScalarEncodingWork.checkpoint() }
            try tokens.writeToken(context: 0, value: UInt32(encoded[i]), to: &writer)
        }
        try checkpoint(); try ScalarEncodingWork.checkpoint()
    }

    private static func variable(_ value: Int, to output: inout [UInt8]) {
        var n = value
        repeat { let byte = UInt8(n & 127); n >>= 7; output.append(byte | (n == 0 ? 0 : 128)) } while n != 0
    }
    private static func variable(_ bytes: [UInt8], _ cursor: inout Int, end: Int) throws -> Int {
        var value: UInt64 = 0
        for i in 0..<10 {
            guard cursor < end else { throw ICCStreamError.malformed }
            let byte = bytes[cursor]; cursor += 1
            guard i < 9 || byte <= 1 else { throw ICCStreamError.malformed }
            value |= UInt64(byte & 127) << (i * 7)
            if byte < 128 {
                guard value <= UInt32.max else { throw ICCStreamError.malformed }
                return Int(value)
            }
        }
        throw ICCStreamError.malformed
    }
    private static func decodeUint32(_ bytes: [UInt8], _ size: Int, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset <= size, size - offset >= 4 else { return 0 }
        return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
    private static func append32(_ n: Int, to bytes: inout [UInt8]) throws {
        guard n >= 0, n <= UInt32.max else { throw ICCStreamError.malformed }
        for shift in [24,16,8,0] { bytes.append(UInt8(truncatingIfNeeded: n >> shift)) }
    }
    private static func byteKind1(_ b: Int) -> Int {
        if (97...122).contains(b) || (65...90).contains(b) { return 0 } // a-z A-Z
        if (48...57).contains(b) { return 1 }                           // 0-9
        if b == 46 || b == 44 { return 1 }                             // . ,
        if b == 0 { return 2 }
        if b == 1 { return 3 }
        if b < 16 { return 4 }
        if b == 255 { return 6 }
        if b > 240 { return 5 }
        return 7
    }
    private static func byteKind2(_ b: Int) -> Int {
        if (97...122).contains(b) || (65...90).contains(b) { return 0 }
        if (48...57).contains(b) { return 1 }
        if b == 46 || b == 44 { return 1 }
        if b < 16 { return 2 }
        if b > 240 { return 3 }
        return 4
    }
    private static func iccANSContext(i: Int, b1: Int, b2: Int) -> Int {
        if i <= 128 { return 0 }
        return 1 + byteKind1(b1) + byteKind2(b2) * 8
    }

    private static func predictValue(
        _ p1: Int, _ p2: Int, _ p3: Int, _ order: Int
    ) -> Int {
        if order == 0 { return p1 }
        if order == 1 { return 2 * p1 - p2 }
        if order == 2 { return 3 * p1 - 3 * p2 + p3 }
        return 0
    }

    private static func iccPredictHeader(
        _ icc: [UInt8], _ size: Int, _ header: inout [UInt8], _ pos: Int
    ) {
        if pos == 8 && size >= 8 {
            header[80] = icc[4]; header[81] = icc[5]
            header[82] = icc[6]; header[83] = icc[7]
        }
        if pos == 41 && size >= 41 {
            if icc[40] == 0x41 {  // 'A'
                header[41] = 0x50; header[42] = 0x50; header[43] = 0x4C // "PPL"
            }
            if icc[40] == 0x4D {  // 'M'
                header[41] = 0x53; header[42] = 0x46; header[43] = 0x54 // "SFT"
            }
        }
        if pos == 42 && size >= 42 {
            if icc[40] == 0x53 && icc[41] == 0x47 {  // "SG"
                header[42] = 0x49; header[43] = 0x20 // "I "
            }
            if icc[40] == 0x53 && icc[41] == 0x55 {  // "SU"
                header[42] = 0x4E; header[43] = 0x57 // "NW"
            }
        }
    }

    /// libjxl `LinearPredictICCValue`.
    private static func linearPredict(
        _ data: [UInt8], _ start: Int, _ i: Int,
        _ stride: Int, _ width: Int, _ order: Int
    ) -> UInt8 {
        let pos = start + i
        if width == 1 {
            let p1 = Int(data[pos - stride])
            let p2 = Int(data[pos - stride * 2])
            let p3 = Int(data[pos - stride * 3])
            return UInt8(truncatingIfNeeded: predictValue(p1, p2, p3, order))
        } else if width == 2 {
            let p = start + (i & ~1)
            let p1 = (Int(data[p - stride]) << 8) + Int(data[p - stride + 1])
            let p2 = (Int(data[p - stride * 2]) << 8)
                + Int(data[p - stride * 2 + 1])
            let p3 = (Int(data[p - stride * 3]) << 8)
                + Int(data[p - stride * 3 + 1])
            let pred = predictValue(p1, p2, p3, order)
            return UInt8(truncatingIfNeeded:
                (i & 1) != 0 ? (pred & 255) : ((pred >> 8) & 255))
        } else {
            let p = start + (i & ~3)
            let p1 = Int(decodeUint32(data, pos, p - stride))
            let p2 = Int(decodeUint32(data, pos, p - stride * 2))
            let p3 = Int(decodeUint32(data, pos, p - stride * 3))
            let pred = predictValue(p1, p2, p3, order)
            let shiftbytes = 3 - (i & 3)
            return UInt8(truncatingIfNeeded: (pred >> (shiftbytes * 8)) & 255)
        }
    }


    package static func unpredict(_ encoded: [UInt8], maximumBytes: Int,
                                  admit: (Int) throws -> Void = { _ in },
                                  checkpoint: () throws -> Void) throws -> Data {
        var pos = 0
        let outputSize = try variable(encoded, &pos, end: encoded.count)
        guard outputSize <= maximumBytes else { throw JPEGEntropyError.resourceLimit }
        let commandSize = try variable(encoded, &pos, end: encoded.count)
        guard commandSize <= encoded.count - pos else { throw ICCStreamError.malformed }
        var cursor = pos; let commandEnd = pos + commandSize; pos = commandEnd
        try admit(outputSize); try checkpoint()
        var result: [UInt8] = []; result.reserveCapacity(outputSize)
        func room(_ count: Int) throws {
            guard count >= 0, count <= outputSize - result.count else { throw ICCStreamError.malformed }
        }
        func data(_ count: Int) throws {
            guard count >= 0, count <= encoded.count - pos else { throw ICCStreamError.malformed }
        }
        var header = initialHeaderPrediction
        for i in 0..<4 { header[i] = UInt8(truncatingIfNeeded: outputSize >> ((3 - i) * 8)) }
        for i in 0..<min(128, outputSize) {
            try data(1); iccPredictHeader(result, result.count, &header, i)
            result.append(encoded[pos] &+ header[i]); pos += 1
        }
        if outputSize > 128 {
            let tagCount = try variable(encoded, &cursor, end: commandEnd)
            if tagCount != 0 {
                try room(4); try append32(tagCount - 1, to: &result)
                var previousStart = 128 + (tagCount - 1) * 12, previousSize = 0
                while cursor < commandEnd {
                    try checkpoint()
                    let command = Int(encoded[cursor]); cursor += 1
                    let code = command & 63
                    if code == 0 { break }
                    let tag: [UInt8]
                    switch code {
                    case 1: try data(4); tag = Array(encoded[pos..<(pos + 4)]); pos += 4
                    case 2: tag = kRtrcTag
                    case 3: tag = kRxyzTag
                    default:
                        guard (4..<(4 + kTagStrings.count)).contains(code) else { throw ICCStreamError.malformed }
                        tag = kTagStrings[code - 4]
                    }
                    let triples = code == 2 || code == 3
                    try room(triples ? 36 : 12)
                    var size = previousSize
                    if [kRxyzTag,kGxyzTag,kBxyzTag,kKxyzTag,kWtptTag,kBkptTag,kLumiTag].contains(tag) { size = 20 }
                    let start = command & 64 != 0 ? try variable(encoded, &cursor, end: commandEnd) : previousStart + previousSize
                    if command & 128 != 0 { size = try variable(encoded, &cursor, end: commandEnd) }
                    result.append(contentsOf: tag); try append32(start, to: &result); try append32(size, to: &result)
                    previousStart = start; previousSize = size
                    if triples {
                        result.append(contentsOf: code == 2 ? kGtrcTag : kGxyzTag)
                        try append32(start + (code == 3 ? size : 0), to: &result); try append32(size, to: &result)
                        result.append(contentsOf: code == 2 ? kBtrcTag : kBxyzTag)
                        try append32(start + (code == 3 ? size * 2 : 0), to: &result); try append32(size, to: &result)
                    }
                }
            }
            while cursor < commandEnd {
                try checkpoint()
                let command = Int(encoded[cursor]); cursor += 1
                if (1...4).contains(command) {
                    var width = command == 2 ? 2 : command == 3 ? 4 : 1, order = 0, stride = 1
                    if command == 4 {
                        guard cursor < commandEnd else { throw ICCStreamError.malformed }
                        let flags = Int(encoded[cursor]); cursor += 1
                        width = (flags & 3) + 1; order = (flags & 12) >> 2
                        guard width != 3, order != 3 else { throw ICCStreamError.malformed }
                        stride = width
                        if flags & 16 != 0 { stride = try variable(encoded, &cursor, end: commandEnd) }
                        guard stride >= width, !result.isEmpty, stride <= (result.count - 1) / 4 else { throw ICCStreamError.malformed }
                    }
                    let count = try variable(encoded, &cursor, end: commandEnd)
                    try room(count); try data(count)
                    let start = result.count, height = (count + width - 1) / width
                    var column = 0, shuffled = 0
                    for i in 0..<count {
                        if i & 1023 == 0 { try checkpoint() }
                        let byte = encoded[pos + shuffled]
                        let prediction: UInt8 = command == 4 ? linearPredict(result, start, i, stride, width, order) : 0
                        result.append(byte &+ prediction)
                        shuffled += height
                        if shuffled >= count { column += 1; shuffled = column }
                    }
                    pos += count
                } else if command == 10 {
                    try room(20); try data(12)
                    result.append(contentsOf: kXyz_Tag); result.append(contentsOf: [0,0,0,0])
                    result.append(contentsOf: encoded[pos..<(pos + 12)]); pos += 12
                } else if (16..<(16 + kTypeStrings.count)).contains(command) {
                    try room(8); result.append(contentsOf: kTypeStrings[command - 16]); result.append(contentsOf: [0,0,0,0])
                } else { throw ICCStreamError.malformed }
            }
        }
        guard cursor == commandEnd, pos == encoded.count, result.count == outputSize else { throw ICCStreamError.malformed }
        try checkpoint(); return Data(result)
    }
}
