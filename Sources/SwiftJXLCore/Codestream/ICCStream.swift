// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

package enum ICCStreamError: Error, Sendable, Equatable {
    case malformed
}

/// ISO/IEC 18181-1 §6.2 & Annex B compressed ICC profile stream reader and writer.
package enum ICCStream {
    private static let numContexts = 41

    private static let tagStrings: [[UInt8]] = [
        Array("cprt".utf8),
        Array("wtpt".utf8),
        Array("bkpt".utf8),
        Array("rXYZ".utf8),
        Array("gXYZ".utf8),
        Array("bXYZ".utf8),
        Array("kXYZ".utf8),
        Array("rTRC".utf8),
        Array("gTRC".utf8),
        Array("bTRC".utf8),
        Array("kTRC".utf8),
        Array("chad".utf8),
        Array("desc".utf8),
        Array("chrm".utf8),
        Array("dmnd".utf8),
        Array("dmdd".utf8),
        Array("lumi".utf8),
    ]

    private static let typeStrings: [[UInt8]] = [
        Array("XYZ ".utf8),
        Array("desc".utf8),
        Array("text".utf8),
        Array("mluc".utf8),
        Array("para".utf8),
        Array("curv".utf8),
        Array("sf32".utf8),
        Array("gbd ".utf8),
    ]

    /// ISO/IEC 18181-1 §6.2 context model for ICC stream bytes.
    @inline(__always)
    private static func iccContext(index: Int, b1: UInt8, b2: UInt8) -> Int {
        if index <= 128 { return 0 }
        let p1: Int
        if (b1 >= 65 && b1 <= 90) || (b1 >= 97 && b1 <= 122) {
            p1 = 0
        } else if (b1 >= 48 && b1 <= 57) || b1 == 46 || b1 == 44 {
            p1 = 1
        } else if b1 <= 1 {
            p1 = 2 + Int(b1)
        } else if b1 < 16 {
            p1 = 4
        } else if b1 > 240 && b1 < 255 {
            p1 = 5
        } else if b1 == 255 {
            p1 = 6
        } else {
            p1 = 7
        }

        let p2: Int
        if (b2 >= 65 && b2 <= 90) || (b2 >= 97 && b2 <= 122) {
            p2 = 0
        } else if (b2 >= 48 && b2 <= 57) || b2 == 46 || b2 == 44 {
            p2 = 1
        } else if b2 < 16 {
            p2 = 2
        } else if b2 > 240 {
            p2 = 3
        } else {
            p2 = 4
        }

        return 1 + p1 + p2 * 8
    }

    /// Reconstructs the 128-byte predicted ICC header template per ISO/IEC 18181-1 Annex B.3.
    private static func initialHeaderTemplate(outputSize: UInt32) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 128)
        header[0] = UInt8(truncatingIfNeeded: outputSize >> 24)
        header[1] = UInt8(truncatingIfNeeded: outputSize >> 16)
        header[2] = UInt8(truncatingIfNeeded: outputSize >> 8)
        header[3] = UInt8(truncatingIfNeeded: outputSize)
        header[8] = 4
        header[12..<16] = [0x6D, 0x6E, 0x74, 0x72] // "mntr"
        header[16..<20] = [0x52, 0x47, 0x42, 0x20] // "RGB "
        header[20..<24] = [0x58, 0x59, 0x5A, 0x20] // "XYZ "
        header[36..<40] = [0x61, 0x63, 0x73, 0x70] // "acsp"
        let d50: [UInt8] = [0, 0, 0xF6, 0xD6, 0, 1, 0, 0, 0, 0, 0xD3, 0x2D]
        for i in 0..<12 { header[68 + i] = d50[i] }
        return header
    }

    private static func updateHeaderTemplateFromCMM(_ header: inout [UInt8], cmm: ArraySlice<UInt8>) {
        let b0 = cmm[cmm.startIndex]
        let b1 = cmm[cmm.startIndex + 1]
        let b2 = cmm[cmm.startIndex + 2]
        let b3 = cmm[cmm.startIndex + 3]
        header[80] = b0
        header[81] = b1
        header[82] = b2
        header[83] = b3
        if (b0 == 0x61 && b1 == 0x70 && b2 == 0x70 && b3 == 0x6C) || // "appl"
           (b0 == 0x61 && b1 == 0x64 && b2 == 0x62 && b3 == 0x65) {  // "adbe"
            header[40..<44] = [0x41, 0x50, 0x50, 0x4C] // "APPL"
        } else if b0 == 0x6D && b1 == 0x73 && b2 == 0x66 && b3 == 0x74 { // "msft"
            header[40..<44] = [0x4D, 0x53, 0x46, 0x54] // "MSFT"
        } else if b0 == 0x73 && b1 == 0x67 && b2 == 0x69 && b3 == 0x20 { // "sgi "
            header[40..<44] = [0x53, 0x47, 0x49, 0x20] // "SGI "
        } else if b0 == 0x74 && b1 == 0x77 && b2 == 0x69 && b3 == 0x20 { // "twi "
            header[40..<44] = [0x54, 0x47, 0x4E, 0x54] // "TGNT"
        }
    }

    @inline(__always)
    private static func readVarint(_ bytes: [UInt8], pos: inout Int, end: Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while pos < end {
            let b = bytes[pos]
            pos += 1
            if shift == 63 && (b & 0x7F) > 1 {
                throw ICCStreamError.malformed
            }
            result |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0 {
                return result
            }
            shift += 7
            if shift > 63 {
                throw ICCStreamError.malformed
            }
        }
        throw ICCStreamError.malformed
    }

    @inline(__always)
    private static func appendVarint(_ value: UInt64, to out: inout [UInt8]) {
        var v = value
        repeat {
            let low = UInt8(v & 0x7F)
            v >>= 7
            out.append(low | (v != 0 ? 0x80 : 0))
        } while v != 0
    }

    @inline(__always)
    private static func writeUInt32BE(_ value: UInt32, into out: inout [UInt8], at offset: Int) {
        out[offset] = UInt8(truncatingIfNeeded: value >> 24)
        out[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        out[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        out[offset + 3] = UInt8(truncatingIfNeeded: value)
    }

    @inline(__always)
    private static func readWordBE(_ out: [UInt8], at offset: Int, width: Int) -> UInt32 {
        switch width {
        case 1:
            return UInt32(out[offset])
        case 2:
            return (UInt32(out[offset]) << 8) | UInt32(out[offset + 1])
        case 4:
            return (UInt32(out[offset]) << 24)
                | (UInt32(out[offset + 1]) << 16)
                | (UInt32(out[offset + 2]) << 8)
                | UInt32(out[offset + 3])
        default:
            return 0
        }
    }

    /// Reconstructs the ICC profile from the Annex B predicted byte stream.
    package static func unpredict(
        _ stream: [UInt8],
        maximumBytes: Int,
        admit: (Int) throws -> Void = { _ in },
        checkpoint: () throws -> Void
    ) throws -> Data {
        try checkpoint()
        guard maximumBytes >= 0 else { throw JPEGEntropyError.resourceLimit }
        var pos = 0
        let streamEnd = stream.count
        let rawOutputSize = try readVarint(stream, pos: &pos, end: streamEnd)
        guard rawOutputSize <= UInt64(maximumBytes), let outputSize = Int(exactly: rawOutputSize) else {
            throw JPEGEntropyError.resourceLimit
        }
        try admit(outputSize)
        guard outputSize >= 128, let outputSizeU32 = UInt32(exactly: outputSize) else {
            throw ICCStreamError.malformed
        }
        let rawCommandsSize = try readVarint(stream, pos: &pos, end: streamEnd)
        guard let commandsSize = Int(exactly: rawCommandsSize),
              commandsSize <= streamEnd - pos else {
            throw ICCStreamError.malformed
        }
        let cmdStart = pos
        let cmdEnd = cmdStart + commandsSize
        var cmdPos = cmdStart
        var dataPos = cmdEnd
        let dataEnd = streamEnd

        guard dataEnd - dataPos >= 128 else {
            throw ICCStreamError.malformed
        }

        var output = [UInt8](repeating: 0, count: outputSize)
        var header = initialHeaderTemplate(outputSize: outputSizeU32)
        for i in 0..<128 {
            if i == 8 {
                updateHeaderTemplateFromCMM(&header, cmm: output[4..<8])
            } else if i == 41 {
                if output[40] == 0x41 || output[40] == 0x61 {
                    header[41] = 0x50
                    header[42] = 0x50
                    header[43] = 0x4C
                } else if output[40] == 0x4D || output[40] == 0x6D {
                    header[41] = 0x53
                    header[42] = 0x46
                    header[43] = 0x54
                }
            }
            output[i] = header[i] &+ stream[dataPos + i]
        }
        dataPos += 128
        var outPos = 128

        if cmdPos < cmdEnd {
            let v = try readVarint(stream, pos: &cmdPos, end: cmdEnd)
            if v > 0 {
                let numTags64 = v - 1
                guard let numTags = UInt32(exactly: numTags64),
                      outPos + 4 <= outputSize else {
                    throw ICCStreamError.malformed
                }
                writeUInt32BE(numTags, into: &output, at: outPos)
                outPos += 4

                let (tagsBytes, tagsOverflow) = numTags.multipliedReportingOverflow(by: 12)
                let (initialPrevPos, posOverflow) = UInt32(128).addingReportingOverflow(tagsBytes)
                guard !tagsOverflow, !posOverflow else {
                    throw ICCStreamError.malformed
                }
                var prevPos: UInt32 = initialPrevPos
                var prevSize: UInt32 = 0

                while true {
                    try checkpoint()
                    guard cmdPos < cmdEnd else { throw ICCStreamError.malformed }
                    let cmd = stream[cmdPos]
                    cmdPos += 1
                    if cmd == 0 { break }

                    let tagcode = cmd & 0x3F
                    let hasOffset = (cmd & 0x40) != 0
                    let hasSize = (cmd & 0x80) != 0

                    let tagPos: UInt32
                    if hasOffset {
                        let rawPos = try readVarint(stream, pos: &cmdPos, end: cmdEnd)
                        guard let p = UInt32(exactly: rawPos) else { throw ICCStreamError.malformed }
                        tagPos = p
                    } else {
                        let (derivedPos, over) = prevPos.addingReportingOverflow(prevSize)
                        guard !over else { throw ICCStreamError.malformed }
                        tagPos = derivedPos
                    }

                    let tagSize: UInt32
                    if hasSize {
                        let rawSize = try readVarint(stream, pos: &cmdPos, end: cmdEnd)
                        guard let s = UInt32(exactly: rawSize) else { throw ICCStreamError.malformed }
                        tagSize = s
                    } else if tagcode == 3 || (5...10).contains(tagcode) {
                        tagSize = 20
                    } else {
                        tagSize = prevSize
                    }

                    prevPos = tagPos
                    prevSize = tagSize

                    if tagcode == 1 {
                        guard dataEnd - dataPos >= 4, outPos + 12 <= outputSize else {
                            throw ICCStreamError.malformed
                        }
                        for k in 0..<4 { output[outPos + k] = stream[dataPos + k] }
                        dataPos += 4
                        writeUInt32BE(tagPos, into: &output, at: outPos + 4)
                        writeUInt32BE(tagSize, into: &output, at: outPos + 8)
                        outPos += 12
                    } else if tagcode == 2 {
                        guard outPos + 36 <= outputSize else { throw ICCStreamError.malformed }
                        for t in 0..<3 {
                            let sig = tagStrings[7 + t] // rTRC, gTRC, bTRC
                            for k in 0..<4 { output[outPos + k] = sig[k] }
                            writeUInt32BE(tagPos, into: &output, at: outPos + 4)
                            writeUInt32BE(tagSize, into: &output, at: outPos + 8)
                            outPos += 12
                        }
                    } else if tagcode == 3 {
                        guard outPos + 36 <= outputSize else { throw ICCStreamError.malformed }
                        var curPos = tagPos
                        for t in 0..<3 {
                            if t > 0 {
                                let (nextPos, over) = curPos.addingReportingOverflow(tagSize)
                                guard !over else { throw ICCStreamError.malformed }
                                curPos = nextPos
                            }
                            let sig = tagStrings[3 + t] // rXYZ, gXYZ, bXYZ
                            for k in 0..<4 { output[outPos + k] = sig[k] }
                            writeUInt32BE(curPos, into: &output, at: outPos + 4)
                            writeUInt32BE(tagSize, into: &output, at: outPos + 8)
                            outPos += 12
                        }
                        prevPos = curPos
                    } else if tagcode >= 4 && Int(tagcode - 4) < tagStrings.count {
                        guard outPos + 12 <= outputSize else { throw ICCStreamError.malformed }
                        let sig = tagStrings[Int(tagcode - 4)]
                        for k in 0..<4 { output[outPos + k] = sig[k] }
                        writeUInt32BE(tagPos, into: &output, at: outPos + 4)
                        writeUInt32BE(tagSize, into: &output, at: outPos + 8)
                        outPos += 12
                    } else {
                        throw ICCStreamError.malformed
                    }
                }
            }
        }

        while cmdPos < cmdEnd {
            try checkpoint()
            let cmd = stream[cmdPos]
            cmdPos += 1
            if cmd == 1 {
                let rawNum = try readVarint(stream, pos: &cmdPos, end: cmdEnd)
                guard let num = Int(exactly: rawNum),
                      num >= 0,
                      num <= outputSize - outPos,
                      num <= dataEnd - dataPos else {
                    throw ICCStreamError.malformed
                }
                for i in 0..<num {
                    if (i & 4095) == 0, i > 0 { try checkpoint() }
                    output[outPos + i] = stream[dataPos + i]
                }
                outPos += num
                dataPos += num
            } else if cmd == 2 || cmd == 3 {
                let rawNum = try readVarint(stream, pos: &cmdPos, end: cmdEnd)
                guard let num = Int(exactly: rawNum),
                      num >= 0,
                      num <= outputSize - outPos,
                      num <= dataEnd - dataPos else {
                    throw ICCStreamError.malformed
                }
                let stride = (cmd == 2) ? 2 : 4
                var groupOffsets = [Int](repeating: 0, count: stride)
                var acc = 0
                for g in 0..<stride {
                    groupOffsets[g] = acc
                    acc += (num - g + stride - 1) / stride
                }
                for i in 0..<num {
                    if (i & 4095) == 0, i > 0 { try checkpoint() }
                    let g = i % stride
                    let srcIndex = dataPos + groupOffsets[g]
                    groupOffsets[g] += 1
                    output[outPos + i] = stream[srcIndex]
                }
                outPos += num
                dataPos += num
            } else if cmd == 4 {
                guard cmdPos < cmdEnd else { throw ICCStreamError.malformed }
                let flags = stream[cmdPos]
                cmdPos += 1
                let width = Int(flags & 3) + 1
                let order = Int((flags >> 2) & 3)
                guard width != 3, order != 3, (flags & 0xE0) == 0 else {
                    throw ICCStreamError.malformed
                }
                let stride: Int
                if (flags & 16) != 0 {
                    let rawStride = try readVarint(stream, pos: &cmdPos, end: cmdEnd)
                    guard let s = Int(exactly: rawStride), s >= width else {
                        throw ICCStreamError.malformed
                    }
                    stride = s
                } else {
                    stride = width
                }
                let rawNum = try readVarint(stream, pos: &cmdPos, end: cmdEnd)
                guard let num = Int(exactly: rawNum),
                      num >= 0,
                      num <= outputSize - outPos,
                      num <= dataEnd - dataPos else {
                    throw ICCStreamError.malformed
                }
                let requiredHistory = stride.multipliedReportingOverflow(by: order + 1)
                guard !requiredHistory.overflow, outPos >= requiredHistory.partialValue else {
                    throw ICCStreamError.malformed
                }
                var groupOffsets = [Int](repeating: 0, count: width)
                var acc = 0
                for g in 0..<width {
                    groupOffsets[g] = acc
                    acc += (num - g + width - 1) / width
                }
                var i = 0
                while i + width <= num {
                    if (i & 4095) == 0, i > 0 { try checkpoint() }
                    let p = outPos + i
                    let w0 = readWordBE(output, at: p - stride, width: width)
                    let pred: UInt32
                    if order == 0 {
                        pred = w0
                    } else if order == 1 {
                        let w1 = readWordBE(output, at: p - 2 * stride, width: width)
                        pred = (w0 &<< 1) &- w1
                    } else {
                        let w1 = readWordBE(output, at: p - 2 * stride, width: width)
                        let w2 = readWordBE(output, at: p - 3 * stride, width: width)
                        pred = (3 &* w0) &- (3 &* w1) &+ w2
                    }
                    for b in 0..<width {
                        let shift = UInt32((width - 1 - b) * 8)
                        let predByte = UInt8(truncatingIfNeeded: pred >> shift)
                        let srcIndex = dataPos + groupOffsets[b]
                        groupOffsets[b] += 1
                        output[p + b] = predByte &+ stream[srcIndex]
                    }
                    i += width
                }
                while i < num {
                    let b = i % width
                    let srcIndex = dataPos + groupOffsets[b]
                    groupOffsets[b] += 1
                    output[outPos + i] = stream[srcIndex]
                    i += 1
                }
                outPos += num
                dataPos += num
            } else if cmd == 10 {
                guard outPos + 20 <= outputSize, dataEnd - dataPos >= 12 else {
                    throw ICCStreamError.malformed
                }
                output[outPos..<outPos + 4] = [0x58, 0x59, 0x5A, 0x20] // "XYZ "
                output[outPos + 4..<outPos + 8] = [0, 0, 0, 0]
                for i in 0..<12 {
                    output[outPos + 8 + i] = stream[dataPos + i]
                }
                outPos += 20
                dataPos += 12
            } else if (16...23).contains(cmd) {
                guard outPos + 8 <= outputSize else {
                    throw ICCStreamError.malformed
                }
                let sig = typeStrings[Int(cmd - 16)]
                for i in 0..<4 { output[outPos + i] = sig[i] }
                output[outPos + 4..<outPos + 8] = [0, 0, 0, 0]
                outPos += 8
            } else {
                throw ICCStreamError.malformed
            }
        }

        guard cmdPos == cmdEnd, outPos == outputSize, dataPos == dataEnd else {
            throw ICCStreamError.malformed
        }
        return Data(output)
    }

    /// Decodes a compressed ICC profile from the bitstream per ISO/IEC 18181-1 §6.2.
    package static func decode(
        from r: inout BitReader,
        maximumBytes: Int,
        checkpoint: () throws -> Void
    ) throws -> Data {
        try checkpoint()
        guard maximumBytes > 0 else { throw JPEGEntropyError.resourceLimit }
        let rawEncSize = try r.readU64()
        let maxEncodedBound = UInt64(maximumBytes) * 2 + 1024
        guard rawEncSize > 0 else { throw ICCStreamError.malformed }
        guard rawEncSize <= maxEncodedBound, let encSize = Int(exactly: rawEncSize) else {
            throw JPEGEntropyError.resourceLimit
        }
        try r.budget?.reserveWorkspace(ScalarOperationBudget.sum(
            ScalarOperationBudget.product(encSize, 4), 65536))
        let header = try EntropySectionHeader.read(from: &r, numContexts: numContexts)
        let codebook = try MultiClusterCodebook.read(from: &r, header: header)
        try r.budget?.reserveWorkspace(ScalarOperationBudget.product(codebook.ansCounts.count, 64 * 1024))
        var stream = TokenStreamReader(header: header, codebook: codebook)

        var encoded = [UInt8](repeating: 0, count: encSize)
        var b1: UInt8 = 0
        var b2: UInt8 = 0
        for i in 0..<encSize {
            if (i & 255) == 0 { try checkpoint() }
            let ctx = iccContext(index: i, b1: b1, b2: b2)
            let sym = try stream.readToken(context: ctx, from: &r)
            guard sym < 256 else { throw ICCStreamError.malformed }
            let byte = UInt8(truncatingIfNeeded: sym)
            encoded[i] = byte
            b2 = b1
            b1 = byte
        }
        try stream.finish()

        return try unpredict(
            encoded,
            maximumBytes: maximumBytes,
            admit: { size in
                try r.budget?.reserveWorkspace(ScalarOperationBudget.product(size, 4))
            },
            checkpoint: checkpoint
        )
    }

    /// Encodes an ICC profile into the bitstream per ISO/IEC 18181-1 §6.2 & Annex B.
    package static func write(
        _ profile: Data,
        to w: inout BitWriter,
        maximumBytes: Int,
        checkpoint: () throws -> Void
    ) throws {
        try checkpoint()
        guard profile.count <= maximumBytes else { throw JPEGEntropyError.resourceLimit }
        guard profile.count >= 128, let outputSizeU32 = UInt32(exactly: profile.count) else {
            throw ICCStreamError.malformed
        }
        let bytes = Array(profile)
        var commands: [UInt8] = [0] // v = 0 (no predicted tag table)
        let tailCount = bytes.count - 128
        if tailCount > 0 {
            commands.append(1) // kLiteral
            appendVarint(UInt64(tailCount), to: &commands)
        }

        var stream: [UInt8] = []
        stream.reserveCapacity(bytes.count + commands.count + 16)
        appendVarint(UInt64(bytes.count), to: &stream)
        appendVarint(UInt64(commands.count), to: &stream)
        stream.append(contentsOf: commands)

        var header = initialHeaderTemplate(outputSize: outputSizeU32)
        for i in 0..<128 {
            if i == 8 {
                updateHeaderTemplateFromCMM(&header, cmm: bytes[4..<8])
            } else if i == 41 {
                if bytes[40] == 0x41 || bytes[40] == 0x61 {
                    header[41] = 0x50
                    header[42] = 0x50
                    header[43] = 0x4C
                } else if bytes[40] == 0x4D || bytes[40] == 0x6D {
                    header[41] = 0x53
                    header[42] = 0x46
                    header[43] = 0x54
                }
            }
            stream.append(bytes[i] &- header[i])
        }
        if tailCount > 0 {
            stream.append(contentsOf: bytes[128..<bytes.count])
        }

        try checkpoint()
        w.writeU64(UInt64(stream.count))
        let uintConfig = HybridUintConfig(splitExponent: 0, msbInToken: 0, lsbInToken: 0)
        let sectionHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: .trivial(numContexts: numContexts),
            usePrefixCode: true,
            logAlphaSize: 15,
            uintConfigs: [uintConfig]
        )
        let lengths = [UInt8](repeating: 4, count: 16)
        let table = try PrefixCodeTable(lengths: lengths)
        let codebook = MultiClusterCodebook(
            huffmanTables: [table],
            ansCounts: [],
            alphabetSizes: [16]
        )
        try sectionHeader.write(to: &w, numContexts: numContexts)
        try codebook.write(to: &w, header: sectionHeader)
        let tokenWriter = TokenStreamWriter(header: sectionHeader, codebook: codebook)
        for (i, byte) in stream.enumerated() {
            if (i & 255) == 0 { try checkpoint() }
            try tokenWriter.writeToken(context: 0, value: UInt32(byte), to: &w)
        }
    }
}
