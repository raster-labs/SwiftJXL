// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift JPEG/JPEGBitWriter, JPEGScanEncoder and JXLToJPEGAdapter
// at 57e81cb9e2411d1efac435b429a306a031744c1e, and libjxl
// a7a9c787341cf703dede03c2009fa460cae5e5df lib/jxl/jpeg/dec_jpeg_data_writer.cc.
// Copyright the JPEG XL Project Authors. See Documentation/ThirdParty/libjxl-LICENSE.txt.
import Foundation

package struct JPEGReconstructionPolicy: Sendable {
    package let maximumOutputBytes: Int
    package let maximumCoefficientBytes: Int
    package let maximumMemoryBytes: Int
    package let maximumBufferedRefinementBits: Int
    package let deadline: ContinuousClock.Instant
    private let work: @Sendable () throws -> Void
    package init(maximumOutputBytes: Int = 64 * 1024 * 1024,
                 maximumCoefficientBytes: Int = 64 * 1024 * 1024,
                 maximumMemoryBytes: Int = 256 * 1024 * 1024,
                 maximumBufferedRefinementBits: Int = 1 << 21,
                 deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(10)),
                 checkpoint: @escaping @Sendable () throws -> Void = {}) throws {
        guard maximumOutputBytes > 0, maximumCoefficientBytes > 0, maximumMemoryBytes > 0,
              (1...(1 << 21)).contains(maximumBufferedRefinementBits) else { throw JPEGEntropyError.resourceLimit }
        self.maximumOutputBytes = maximumOutputBytes; self.maximumCoefficientBytes = maximumCoefficientBytes
        self.maximumMemoryBytes = maximumMemoryBytes; self.maximumBufferedRefinementBits = maximumBufferedRefinementBits
        self.deadline = deadline; self.work = checkpoint
    }
    package func checkpoint() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw JPEGEntropyError.resourceLimit }
        try work()
    }
}

/// JPEG reconstruction from coefficient owners and resolved metadata only.
/// There is deliberately no source-JPEG parameter or pixel/re-encoding fallback.
package enum JPEGReconstructionWriter {
    package static func write(coefficients: [[Int32]], metadata: JBRDBox,
                              policy: JPEGReconstructionPolicy) throws -> Data {
        var writer = try ReconstructionWriter(coefficients: coefficients, box: metadata, policy: policy)
        return try writer.write()
    }
}

private struct JPEGOutput {
    var data = Data()
    private var accumulator: UInt64 = 0
    private var pending = 0
    let limit: Int
    let policy: JPEGReconstructionPolicy
    mutating func byte(_ byte: UInt8) throws {
        guard data.count < limit else { throw JPEGEntropyError.resourceLimit }
        if data.count & 1023 == 0 { try policy.checkpoint() }
        data.append(byte)
    }
    mutating func bytes(_ bytes: Data) throws {
        guard pending == 0, bytes.count <= limit - data.count else { throw JPEGEntropyError.resourceLimit }
        var offset = 0
        while offset < bytes.count {
            try policy.checkpoint()
            let end = offset + min(4096, bytes.count - offset)
            data.append(bytes[(bytes.startIndex + offset)..<(bytes.startIndex + end)]); offset = end
        }
    }
    mutating func bits(_ value: UInt64, _ count: Int) throws {
        guard (0...24).contains(count) else { throw JPEGEntropyError.malformed }
        if count == 0 { return }
        accumulator = (accumulator << count) | (value & ((1 << count) - 1)); pending += count
        while pending >= 8 {
            pending -= 8
            let b = UInt8(truncatingIfNeeded: accumulator >> pending)
            try byte(b); if b == 0xff { try byte(0) }
        }
    }
    mutating func align(_ padding: [UInt8], exact: Bool, cursor: inout Int) throws {
        let count = pending == 0 ? 0 : 8 - pending
        if exact {
            guard count <= padding.count - cursor else { throw JPEGEntropyError.malformed }
            for _ in 0..<count {
                let bit = padding[cursor]; guard bit <= 1 else { throw JPEGEntropyError.malformed }
                try bits(UInt64(bit), 1); cursor += 1
            }
        } else { try bits((1 << count) - 1, count) }
    }
    mutating func marker(_ code: UInt8) throws {
        guard pending == 0 else { throw JPEGEntropyError.malformed }
        try byte(0xff); try byte(code)
    }
    mutating func segment(_ code: UInt8, _ payload: Data) throws {
        guard payload.count <= 65533 else { throw JPEGEntropyError.resourceLimit }
        try marker(code)
        let n = payload.count + 2
        try byte(UInt8(n >> 8)); try byte(UInt8(n & 255)); try bytes(payload)
    }
}

private struct JPEGEncodeTable {
    var code = [UInt32](repeating: 0, count: 256)
    var length = [Int](repeating: 0, count: 256)
    init(_ table: JBRDHuffmanCode) throws {
        guard table.counts.count == 17, table.values.last == 256 else { throw JPEGEntropyError.malformed }
        var value = 0, cursor = 0
        for n in 1...16 {
            for _ in 0..<Int(table.counts[n]) {
                guard cursor < table.values.count, value < 1 << n else { throw JPEGEntropyError.malformed }
                let symbol = Int(table.values[cursor]); cursor += 1
                if symbol != 256 {
                    guard (0...255).contains(symbol), length[symbol] == 0, value != (1 << n) - 1 else {
                        throw JPEGEntropyError.malformed
                    }
                    code[symbol] = UInt32(value); length[symbol] = n
                }
                value += 1
            }
            value <<= 1
        }
        guard cursor == table.values.count else { throw JPEGEntropyError.malformed }
    }
}

private struct ReconstructionWriter {
    let coefficients: [[Int32]]
    let box: JBRDBox
    let policy: JPEGReconstructionPolicy
    let frame: JPEGFrameLayout
    var output: JPEGOutput
    var tables: [JPEGEncodeTable?] = Array(repeating: nil, count: 8)
    var history: [[Int]]
    var paddingCursor = 0
    var eobRun = 0
    var eobTable = 0
    var refinement: [UInt8] = []
    var predictors = [Int64](repeating: 0, count: 3)

    init(coefficients: [[Int32]], box: JBRDBox, policy: JPEGReconstructionPolicy) throws {
        try policy.checkpoint()
        guard coefficients.count == box.components.count, coefficients.count == 1 || coefficients.count == 3,
              (1...65535).contains(box.width), (1...65535).contains(box.height) else { throw JPEGEntropyError.malformed }
        var retained = 0
        func reserve(_ count: Int, _ stride: Int) throws {
            try policy.checkpoint()
            guard count >= 0, count <= (policy.maximumMemoryBytes - retained) / stride else { throw JPEGEntropyError.resourceLimit }
            retained += count * stride
        }
        var totalCoefficients = 0
        for plane in coefficients {
            guard plane.count <= policy.maximumCoefficientBytes / 4 - totalCoefficients else { throw JPEGEntropyError.resourceLimit }
            totalCoefficients += plane.count; try reserve(plane.count, 4)
        }
        try reserve(1 << 20, 1) // Tables, bounded marker scratch, histories, allocator allowance.
        try reserve(policy.maximumBufferedRefinementBits, 4) // Buffer growth and retained capacity.
        try reserve(box.markerOrder.count, 1024)
        try reserve(box.paddingBits.count, 4)
        for scan in box.scanInfo { try reserve(scan.resetPoints.count, 32); try reserve(scan.extraZeroRuns.count, 32) }
        for group in [box.appData, box.comData, box.interMarkerData, [box.tailData]] {
            for bytes in group { try reserve(bytes.count, 2) }
        }
        // Validate the full wire shape/semantics before indexing supplied arrays.
        _ = try JBRDBoxWriter.write(box, policy: JBRDPolicy(maximumMemoryBytes: policy.maximumMemoryBytes - retained,
                                                         deadline: policy.deadline, checkpoint: policy.checkpoint))
        let markers = box.markerOrder.filter { (0xc0...0xc2).contains($0) }
        guard markers.count == 1, let marker = markers.first else { throw JPEGEntropyError.unsupported }
        var sof = Data([8, UInt8(box.height >> 8), UInt8(box.height & 255), UInt8(box.width >> 8),
                        UInt8(box.width & 255), UInt8(box.components.count)])
        for c in box.components {
            guard (1...4).contains(c.hSampFactor), (1...4).contains(c.vSampFactor), c.quantIdx < box.quant.count else {
                throw JPEGEntropyError.malformed
            }
            sof.append(contentsOf: [UInt8(c.id), UInt8(c.hSampFactor * 16 + c.vSampFactor), UInt8(box.quant[Int(c.quantIdx)].index)])
        }
        var packet = Data([0xff, marker, 0, UInt8(sof.count + 2)]); packet.append(sof)
        let segment = JPEGSegment(markerByte: marker, markerRange: 0..<2, payloadRange: 4..<packet.count,
                                  entropyRange: packet.count..<packet.count)
        frame = try JPEGFrameLayout(data: packet, segment: segment, maximumCoefficientBytes: policy.maximumCoefficientBytes)
        for i in frame.components.indices {
            let c = frame.components[i]
            guard coefficients[i].count == c.paddedBlocksWide * c.paddedBlocksHigh * 64,
                  box.components[i].widthInBlocks == c.paddedBlocksWide,
                  box.components[i].heightInBlocks == c.paddedBlocksHigh else { throw JPEGEntropyError.malformed }
        }
        for q in box.quant {
            guard q.values.count == 64, q.values.allSatisfy({ $0 > 0 && $0 <= (q.precision == 0 ? 255 : 65535) }) else {
                throw JPEGEntropyError.malformed
            }
        }
        self.coefficients = coefficients; self.box = box; self.policy = policy
        history = coefficients.map { _ in [Int](repeating: -1, count: 64) }
        output = JPEGOutput(limit: min(policy.maximumOutputBytes, (policy.maximumMemoryBytes - retained) / 3), policy: policy)
    }

    mutating func write() throws -> Data {
        try output.marker(0xd8)
        var quant = 0, huffman = 0, app = 0, com = 0, inter = 0, scan = 0
        var seenFrame = false, seenDRI = false, interval = 0
        var activeQuant = [Int?](repeating: nil, count: 4)
        var componentQuantSeen = [Bool](repeating: false, count: frame.components.count)
        for marker in box.markerOrder {
            try policy.checkpoint()
            switch marker {
            case 0xdb:
                var bytes = Data(), last = false
                while quant < box.quant.count && !last {
                    let q = box.quant[quant]; activeQuant[Int(q.index)] = quant; quant += 1; last = q.isLast
                    bytes.append(UInt8(q.precision * 16 + q.index))
                    for k in JPEGZigZag.order {
                        let v = q.values[k]
                        if q.precision == 1 { bytes.append(UInt8(v >> 8)) }
                        bytes.append(UInt8(truncatingIfNeeded: v))
                    }
                }
                guard last else { throw JPEGEntropyError.malformed }; try output.segment(marker, bytes)
            case 0xc4:
                var bytes = Data(), last = false
                while huffman < box.huffmanCode.count && !last {
                    let h = box.huffmanCode[huffman]; huffman += 1; last = h.isLast
                    tables[(h.slotId & 3) + (h.slotId >= 16 ? 4 : 0)] = try JPEGEncodeTable(h)
                    guard let end = h.counts.lastIndex(where: { $0 > 0 }) else { throw JPEGEntropyError.malformed }
                    bytes.append(UInt8(h.slotId))
                    for n in 1...16 { bytes.append(UInt8(h.counts[n] - (n == end ? 1 : 0))) }
                    for v in h.values.dropLast() { bytes.append(UInt8(v)) }
                }
                guard last else { throw JPEGEntropyError.malformed }; try output.segment(marker, bytes)
            case 0xc0...0xc2:
                guard !seenFrame else { throw JPEGEntropyError.malformed }; seenFrame = true
                var bytes = Data([8, UInt8(frame.height >> 8), UInt8(frame.height & 255), UInt8(frame.width >> 8),
                                  UInt8(frame.width & 255), UInt8(frame.components.count)])
                for c in frame.components { bytes.append(contentsOf: [c.id, UInt8(c.horizontalSampling * 16 + c.verticalSampling), c.quantisationTable]) }
                try output.segment(marker, bytes)
            case 0xdd:
                guard !seenDRI else { throw JPEGEntropyError.unsupported }; seenDRI = true
                interval = Int(box.restartInterval)
                try output.segment(marker, Data([UInt8(interval >> 8), UInt8(interval & 255)]))
            case 0xe0...0xef, 0xfe:
                let bytes: Data
                if marker == 0xfe { bytes = box.comData[com]; com += 1 }
                else { bytes = box.appData[app]; app += 1 }
                guard bytes.count >= 3, bytes[bytes.startIndex] == marker,
                      Int(bytes[bytes.startIndex + 1]) * 256 + Int(bytes[bytes.startIndex + 2]) == bytes.count - 1 else {
                    throw JPEGEntropyError.malformed
                }
                try output.byte(0xff); try output.bytes(bytes)
            case 0xff: try output.bytes(box.interMarkerData[inter]); inter += 1
            case 0xda:
                guard seenFrame else { throw JPEGEntropyError.malformed }
                for c in box.scanInfo[scan].components {
                    let ci = Int(c.compIdx)
                    if !componentQuantSeen[ci] {
                        guard activeQuant[Int(frame.components[ci].quantisationTable)] == Int(box.components[ci].quantIdx) else {
                            throw JPEGEntropyError.malformed
                        }
                        componentQuantSeen[ci] = true
                    }
                }
                try writeScan(box.scanInfo[scan], interval: interval); scan += 1
            case 0xd9: try output.marker(marker)
            default: throw JPEGEntropyError.unsupported
            }
        }
        guard quant == box.quant.count, huffman == box.huffmanCode.count,
              paddingCursor == box.paddingBits.count, history.allSatisfy({ $0[0] >= 0 }) else { throw JPEGEntropyError.malformed }
        // An inconsistent frame must not silently discard unscanned/lower bits.
        var inverse = [Int](repeating: 0, count: 64)
        for k in 0..<64 { inverse[JPEGZigZag.order[k]] = k }
        for ci in coefficients.indices {
            for index in coefficients[ci].indices {
                if index & 1023 == 0 { try policy.checkpoint() }
                let shift = history[ci][inverse[index & 63]]
                let value = Int64(coefficients[ci][index])
                guard shift >= 0 ? value & ((1 << shift) - 1) == 0 : value == 0 else { throw JPEGEntropyError.malformed }
            }
        }
        try output.bytes(box.tailData); try policy.checkpoint()
        return output.data
    }

    mutating func symbol(_ symbol: Int, table: Int) throws {
        guard (0..<8).contains(table), (0..<256).contains(symbol), let h = tables[table], h.length[symbol] > 0 else {
            throw JPEGEntropyError.malformed
        }
        try output.bits(UInt64(h.code[symbol]), h.length[symbol])
    }
    func size(_ value: Int64) -> Int { value == 0 ? 0 : 64 - UInt64(abs(value)).leadingZeroBitCount }
    mutating func magnitude(_ value: Int64, count: Int) throws {
        try output.bits(UInt64(truncatingIfNeeded: value < 0 ? value - 1 : value), count)
    }
    mutating func flushEOB() throws {
        if eobRun > 0 {
            let n = size(Int64(eobRun)) - 1
            try symbol(n << 4, table: eobTable); try output.bits(UInt64(eobRun), n); eobRun = 0
        }
        for (i, bit) in refinement.enumerated() {
            if i & 1023 == 0 { try policy.checkpoint() }
            try output.bits(UInt64(bit), 1)
        }
        refinement.removeAll(keepingCapacity: true)
    }
    mutating func endOfBand(table: Int, bits: [UInt8] = []) throws {
        guard bits.count <= policy.maximumBufferedRefinementBits - refinement.count else { throw JPEGEntropyError.resourceLimit }
        if eobRun == 0 { eobTable = table }
        guard eobTable == table else { throw JPEGEntropyError.malformed }
        eobRun += 1; refinement.append(contentsOf: bits)
        if eobRun == 32767 { try flushEOB() }
    }

    mutating func writeScan(_ scan: JBRDScanInfo, interval: Int) throws {
        let ss = Int(scan.ss), se = Int(scan.se), ah = Int(scan.ah), al = Int(scan.al)
        let progressive = frame.marker == 0xc2
        guard Set(scan.components.map(\.compIdx)).count == scan.components.count else { throw JPEGEntropyError.malformed }
        if progressive {
            guard (ss == 0 && se == 0) || (ss > 0 && ss <= se && scan.components.count == 1),
                  ah == 0 || ah == al + 1 else { throw JPEGEntropyError.malformed }
        } else { guard ss == 0, se == 63, ah == 0, al == 0 else { throw JPEGEntropyError.malformed } }
        for c in scan.components {
            let ci = Int(c.compIdx)
            for k in ss...se {
                guard ah == 0 ? history[ci][k] == -1 : history[ci][k] == ah else { throw JPEGEntropyError.malformed }
                history[ci][k] = al
            }
        }
        var header = Data([UInt8(scan.components.count)])
        for c in scan.components { header.append(contentsOf: [frame.components[Int(c.compIdx)].id, UInt8(c.dcTblIdx * 16 + c.acTblIdx)]) }
        header.append(contentsOf: [UInt8(ss), UInt8(se), UInt8(ah * 16 + al)])
        try output.segment(0xda, header)
        predictors = [0, 0, 0]; eobRun = 0; refinement.removeAll(keepingCapacity: true)
        let interleaved = scan.components.count > 1
        let first = frame.components[Int(scan.components[0].compIdx)]
        let wide = interleaved ? frame.mcusWide : first.visibleBlocksWide
        let high = interleaved ? frame.mcusHigh : first.visibleBlocksHigh
        var blockOrdinal = 0, reset = 0, extra = 0, restart = 0
        for mcu in 0..<(wide * high) {
            try policy.checkpoint()
            if mcu > 0 && interval > 0 && mcu % interval == 0 {
                try flushEOB(); try output.align(box.paddingBits, exact: box.hasZeroPaddingBit, cursor: &paddingCursor)
                try output.marker(UInt8(0xd0 + restart)); restart = (restart + 1) & 7; predictors = [0, 0, 0]
            }
            for c in scan.components {
                let ci = Int(c.compIdx), layout = frame.components[ci]
                let h = interleaved ? layout.horizontalSampling : 1, v = interleaved ? layout.verticalSampling : 1
                for y in 0..<v { for x in 0..<h {
                    try policy.checkpoint()
                    if reset < scan.resetPoints.count && Int(scan.resetPoints[reset]) == blockOrdinal { try flushEOB(); reset += 1 }
                    var zeroRuns = 0
                    if extra < scan.extraZeroRuns.count && Int(scan.extraZeroRuns[extra].blockIdx) == blockOrdinal {
                        zeroRuns = Int(scan.extraZeroRuns[extra].numExtraZeroRuns); extra += 1
                    }
                    let index = ((mcu / wide * v + y) * layout.paddedBlocksWide + mcu % wide * h + x) * 64
                    if progressive && ah > 0 {
                        guard zeroRuns == 0 else { throw JPEGEntropyError.unsupported }
                        try refine(ci: ci, base: index, ss: ss, se: se, al: al, ac: Int(c.acTblIdx) + 4)
                    } else {
                        try initial(ci: ci, base: index, ss: ss, se: se, al: al, dc: Int(c.dcTblIdx), ac: Int(c.acTblIdx) + 4,
                                    extraZeros: zeroRuns, groupEOB: progressive && ss > 0)
                    }
                    blockOrdinal += 1
                } }
            }
        }
        guard reset == scan.resetPoints.count, extra == scan.extraZeroRuns.count else { throw JPEGEntropyError.malformed }
        try flushEOB(); try output.align(box.paddingBits, exact: box.hasZeroPaddingBit, cursor: &paddingCursor)
    }

    mutating func initial(ci: Int, base: Int, ss: Int, se: Int, al: Int, dc: Int, ac: Int,
                          extraZeros: Int, groupEOB: Bool) throws {
        var start = ss
        if start == 0 {
            let value = Int64(coefficients[ci][base]) >> al, difference = value - predictors[ci]
            predictors[ci] = value; let n = size(difference)
            guard n <= 11 else { throw JPEGEntropyError.malformed }
            try symbol(n, table: dc); try magnitude(difference, count: n); start = 1
        }
        if start > se { guard extraZeros == 0 else { throw JPEGEntropyError.malformed }; return }
        var zeros = 0
        for k in start...se {
            let raw = Int64(coefficients[ci][base + JPEGZigZag.order[k]])
            let value = (raw < 0 ? -1 : 1) * (abs(raw) >> al)
            if value == 0 { zeros += 1; continue }
            try flushEOB()
            while zeros >= 16 { try symbol(0xf0, table: ac); zeros -= 16 }
            let n = size(value); guard n <= 10 else { throw JPEGEntropyError.malformed }
            try symbol(zeros * 16 + n, table: ac); try magnitude(value, count: n); zeros = 0
        }
        if extraZeros > 0 {
            guard extraZeros <= zeros / 16 else { throw JPEGEntropyError.malformed }
            try flushEOB()
            for _ in 0..<extraZeros { try symbol(0xf0, table: ac); zeros -= 16 }
        }
        if zeros > 0 { try endOfBand(table: ac); if !groupEOB { try flushEOB() } }
    }

    mutating func refine(ci: Int, base: Int, ss: Int, se: Int, al: Int, ac: Int) throws {
        var start = ss
        if start == 0 { try output.bits(UInt64(truncatingIfNeeded: Int64(coefficients[ci][base]) >> al) & 1, 1); start = 1 }
        if start > se { return }
        var values = [Int64](repeating: 0, count: 64), end = 0
        for k in start...se {
            values[k] = abs(Int64(coefficients[ci][base + JPEGZigZag.order[k]])) >> al
            if values[k] == 1 { end = k }
        }
        var zeros = 0, bits: [UInt8] = []
        for k in start...se {
            if values[k] == 0 { zeros += 1; continue }
            while zeros > 15 && k <= end {
                try flushEOB(); try symbol(0xf0, table: ac); zeros -= 16
                for bit in bits { try output.bits(UInt64(bit), 1) }; bits.removeAll(keepingCapacity: true)
            }
            if values[k] > 1 { bits.append(UInt8(values[k] & 1)); continue }
            try flushEOB(); try symbol(zeros * 16 + 1, table: ac)
            try output.bits(coefficients[ci][base + JPEGZigZag.order[k]] < 0 ? 0 : 1, 1)
            for bit in bits { try output.bits(UInt64(bit), 1) }; bits.removeAll(keepingCapacity: true); zeros = 0
        }
        if zeros > 0 || !bits.isEmpty { try endOfBand(table: ac, bits: bits) }
    }
}
