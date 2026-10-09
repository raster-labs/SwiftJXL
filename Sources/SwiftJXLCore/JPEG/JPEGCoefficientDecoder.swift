// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift JPEGCoefficientImage/JPEGScanDecoder/JPEGBlockDecoder
// at 57e81cb9e2411d1efac435b429a306a031744c1e. T.81 F.2 and G.2.
import Foundation

package struct JPEGDecodedCoefficients: Sendable {
    package let source: Data
    package let frame: JPEGFrameLayout
    /// Natural-order Int32 coefficients in each component's padded grid.
    package let coefficients: [[Int32]]
    /// Natural-order quantisation values latched at each component's first scan.
    package let quantisation: [[UInt16]]
    package let padding: [JPEGEntropyPadding]
}

package struct JPEGCoefficientPolicy: Sendable {
    package let maximumInputBytes: Int
    package let maximumCoefficientBytes: Int
    package let maximumMemoryBytes: Int
    package let maximumPaddingRecords: Int
    package let deadline: ContinuousClock.Instant
    private let workCheckpoint: @Sendable () throws -> Void

    package init(maximumInputBytes: Int = 64 * 1024 * 1024,
                 maximumCoefficientBytes: Int = 64 * 1024 * 1024,
                 maximumMemoryBytes: Int = 256 * 1024 * 1024,
                 maximumPaddingRecords: Int = 65536,
                 deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(10)),
                 checkpoint: @escaping @Sendable () throws -> Void = {}) throws {
        guard maximumInputBytes > 0, maximumCoefficientBytes > 0, maximumMemoryBytes > 0,
              (1...65536).contains(maximumPaddingRecords) else { throw JPEGEntropyError.resourceLimit }
        self.maximumInputBytes = maximumInputBytes; self.maximumCoefficientBytes = maximumCoefficientBytes
        self.maximumMemoryBytes = maximumMemoryBytes; self.maximumPaddingRecords = maximumPaddingRecords
        self.deadline = deadline
        self.workCheckpoint = checkpoint
    }

    package func checkpoint() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw JPEGEntropyError.resourceLimit }
        try workCheckpoint()
    }

    fileprivate func admit(input: Int, coefficients: Int) throws {
        try checkpoint()
        guard input <= maximumInputBytes, input <= maximumMemoryBytes else { throw JPEGEntropyError.resourceLimit }
        // Two coefficient bounds cover storage/transient overlap. Fixed table,
        // history and parser scratch plus four padding-array capacity bounds.
        let auxiliary = 2 * 1024 * 1024 + maximumPaddingRecords * 128
        guard auxiliary <= maximumMemoryBytes - input,
              coefficients <= maximumCoefficientBytes / 4,
              coefficients <= (maximumMemoryBytes - input - auxiliary) / 8 else {
            throw JPEGEntropyError.resourceLimit
        }
    }
}

package struct JPEGCoefficientDecoder {
    private let data: Data
    private let policy: JPEGCoefficientPolicy
    private var huffman: [JPEGHuffmanTable?] = Array(repeating: nil, count: 8)
    private var quantisation: [[UInt16]?] = Array(repeating: nil, count: 4)
    private var componentQuantisation: [[UInt16]] = []
    private var coefficients: [[Int32]] = []
    private var history: [[Int]] = []
    private var padding: [JPEGEntropyPadding] = []

    package static func decode(_ data: Data, policy: JPEGCoefficientPolicy) throws -> JPEGDecodedCoefficients {
        try policy.admit(input: data.count, coefficients: 0)
        var decoder = Self(data: data, policy: policy)
        return try decoder.decode()
    }

    private func byte(_ position: Int) -> UInt8 { data[data.startIndex + position] }

    private mutating func decode() throws -> JPEGDecodedCoefficients {
        var reader = try JPEGSegmentReader(data, maximumInputBytes: policy.maximumInputBytes,
                                          deadline: policy.deadline, checkpoint: policy.checkpoint)
        var frame: JPEGFrameLayout?
        var restartInterval = 0
        while let segment = try reader.next() {
            try policy.checkpoint()
            switch segment.markerByte {
            case 0xd8, 0xd9, 0xe0...0xef, 0xfe: break
            case 0xc0...0xc2:
                guard frame == nil else { throw JPEGEntropyError.unsupported }
                let layout = try JPEGFrameLayout(data: data, segment: segment,
                                                maximumCoefficientBytes: policy.maximumCoefficientBytes)
                try policy.admit(input: data.count, coefficients: layout.coefficientCount)
                coefficients = layout.components.map {
                    Array(repeating: 0, count: $0.paddedBlocksWide * $0.paddedBlocksHigh * 64)
                }
                history = layout.components.map { _ in Array(repeating: -1, count: 64) }
                componentQuantisation = layout.components.map { _ in [] }
                frame = layout
            case 0xdb: try parseQuantisation(segment.payloadRange)
            case 0xc4: try parseHuffman(segment.payloadRange)
            case 0xdd:
                guard segment.payloadRange.count == 2 else { throw JPEGEntropyError.malformed }
                let start = segment.payloadRange.lowerBound
                restartInterval = Int(byte(start)) * 256 + Int(byte(start + 1))
            case 0xda:
                guard let frame else { throw JPEGEntropyError.malformed }
                try decodeScan(segment, frame: frame, restartInterval: restartInterval)
            default: throw JPEGEntropyError.unsupported
            }
        }
        guard let frame, history.allSatisfy({ $0[0] >= 0 }),
              componentQuantisation.allSatisfy({ $0.count == 64 }) else { throw JPEGEntropyError.malformed }
        try policy.checkpoint()
        return JPEGDecodedCoefficients(source: data, frame: frame, coefficients: coefficients,
                                       quantisation: componentQuantisation, padding: padding)
    }

    private mutating func parseQuantisation(_ range: Range<Int>) throws {
        guard !range.isEmpty else { throw JPEGEntropyError.malformed }
        var offset = range.lowerBound
        while offset < range.upperBound {
            try policy.checkpoint()
            let info = byte(offset); offset += 1
            let precision = Int(info >> 4), id = Int(info & 15)
            guard precision <= 1, id < 4, range.upperBound - offset >= 64 * (precision + 1) else {
                throw JPEGEntropyError.malformed
            }
            var values = Array<UInt16>(repeating: 0, count: 64)
            for k in 0..<64 {
                var value = UInt16(byte(offset)); offset += 1
                if precision == 1 { value = value * 256 + UInt16(byte(offset)); offset += 1 }
                guard value > 0 else { throw JPEGEntropyError.malformed }
                values[JPEGZigZag.order[k]] = value
            }
            quantisation[id] = values
        }
    }

    private mutating func parseHuffman(_ range: Range<Int>) throws {
        guard !range.isEmpty else { throw JPEGEntropyError.malformed }
        var offset = range.lowerBound
        while offset < range.upperBound {
            try policy.checkpoint()
            guard range.upperBound - offset >= 17 else { throw JPEGEntropyError.malformed }
            let info = byte(offset); offset += 1
            let kind = Int(info >> 4), id = Int(info & 15)
            guard kind <= 1, id < 4 else { throw JPEGEntropyError.malformed }
            let counts = (0..<16).map { Int(byte(offset + $0)) }; offset += 16
            let total = counts.reduce(0, +)
            guard total <= 256, total <= range.upperBound - offset else { throw JPEGEntropyError.malformed }
            let symbols = (0..<total).map { byte(offset + $0) }; offset += total
            guard symbols.allSatisfy({ kind == 0 ? $0 <= 11 : ($0 & 15) <= 10 }) else {
                throw JPEGEntropyError.malformed
            }
            huffman[kind * 4 + id] = try JPEGHuffmanTable(counts: counts, symbols: symbols)
        }
    }

    private mutating func appendPadding(_ value: JPEGEntropyPadding) throws {
        guard padding.count < policy.maximumPaddingRecords else { throw JPEGEntropyError.resourceLimit }
        padding.append(value)
    }

    private struct ScanComponent { let index: Int; let dc: Int; let ac: Int }

    private mutating func decodeScan(_ segment: JPEGSegment, frame: JPEGFrameLayout, restartInterval: Int) throws {
        let start = segment.payloadRange.lowerBound
        guard segment.payloadRange.count >= 4 else { throw JPEGEntropyError.malformed }
        let count = Int(byte(start))
        guard (1...frame.components.count).contains(count), segment.payloadRange.count == 4 + 2 * count else {
            throw JPEGEntropyError.malformed
        }
        var components: [ScanComponent] = []
        for i in 0..<count {
            let id = byte(start + 1 + 2 * i), tables = byte(start + 2 + 2 * i)
            guard let ci = frame.components.firstIndex(where: { $0.id == id }),
                  !components.contains(where: { $0.index == ci }), tables >> 4 < 4, tables & 15 < 4 else {
                throw JPEGEntropyError.malformed
            }
            components.append(ScanComponent(index: ci, dc: Int(tables >> 4), ac: Int(tables & 15)))
            if componentQuantisation[ci].isEmpty {
                guard let table = quantisation[Int(frame.components[ci].quantisationTable)] else {
                    throw JPEGEntropyError.malformed
                }
                componentQuantisation[ci] = table
            }
        }
        let ss = Int(byte(start + 1 + 2 * count)), se = Int(byte(start + 2 + 2 * count))
        let ah = Int(byte(start + 3 + 2 * count) >> 4), al = Int(byte(start + 3 + 2 * count) & 15)
        let progressive = frame.marker == 0xc2
        if progressive {
            guard ss <= se, se < 64, ah <= 13, al <= 13, ah == 0 || ah == al + 1,
                  ss == 0 ? se == 0 : count == 1 else { throw JPEGEntropyError.malformed }
        } else {
            guard ss == 0, se == 63, ah == 0, al == 0 else { throw JPEGEntropyError.malformed }
        }
        for component in components {
            let ci = component.index
            if ss > 0 && history[ci][0] < 0 { throw JPEGEntropyError.malformed }
            for k in ss...se {
                guard history[ci][k] == (ah == 0 ? -1 : ah) else { throw JPEGEntropyError.malformed }
                history[ci][k] = al
            }
        }
        if count > 1 {
            let blocks = components.reduce(0) { $0 + frame.components[$1.index].horizontalSampling * frame.components[$1.index].verticalSampling }
            guard blocks <= 10 else { throw JPEGEntropyError.malformed }
        }
        var bits = try JPEGEntropyReader(data: data, range: segment.entropyRange, checkpoint: policy.checkpoint)
        var predictors = Array<Int32>(repeating: 0, count: frame.components.count)
        var eobRun = 0, restartNumber: UInt8 = 0
        let total = count == 1 ? frame.components[components[0].index].singleComponentBlockCount : frame.mcusWide * frame.mcusHigh
        for mcu in 0..<total {
            try policy.checkpoint()
            if mcu > 0 && restartInterval > 0 && mcu % restartInterval == 0 {
                guard eobRun == 0 else { throw JPEGEntropyError.malformed }
                try appendPadding(bits.restart(0xd0 + restartNumber))
                restartNumber = (restartNumber + 1) & 7
                predictors = Array(repeating: 0, count: predictors.count)
            }
            for component in components {
                let ci = component.index, geometry = frame.components[ci]
                let blockCount = count == 1 ? 1 : geometry.horizontalSampling * geometry.verticalSampling
                for ordinal in 0..<blockCount {
                    let block: Int
                    if count == 1 { block = try geometry.storageIndex(forSingleComponentBlock: mcu) }
                    else {
                        let row = (mcu / frame.mcusWide) * geometry.verticalSampling + ordinal / geometry.horizontalSampling
                        let column = (mcu % frame.mcusWide) * geometry.horizontalSampling + ordinal % geometry.horizontalSampling
                        block = row * geometry.paddedBlocksWide + column
                    }
                    try Self.decodeBlock(values: &coefficients[ci], base: block * 64, bits: &bits,
                        dc: huffman[component.dc], ac: huffman[4 + component.ac], predictor: &predictors[ci],
                        ss: ss, se: se, ah: ah, al: al, progressive: progressive, eobRun: &eobRun)
                }
            }
        }
        guard eobRun == 0 else { throw JPEGEntropyError.malformed }
        try appendPadding(bits.finish())
    }

    private static func decodeBlock(values: inout [Int32], base: Int, bits: inout JPEGEntropyReader,
                                    dc: JPEGHuffmanTable?, ac: JPEGHuffmanTable?, predictor: inout Int32,
                                    ss: Int, se: Int, ah: Int, al: Int, progressive: Bool, eobRun: inout Int) throws {
        if ss == 0 {
            if ah == 0 {
                guard let dc else { throw JPEGEntropyError.malformed }
                let category = Int(try dc.symbol(&bits))
                let delta = try bits.magnitude(category)
                let (next, overflow) = predictor.addingReportingOverflow(delta)
                guard !overflow, next >= -32768, next <= 32767 else { throw JPEGEntropyError.malformed }
                predictor = next
                let shifted = Int64(next) * (1 << al)
                guard shifted >= Int64(Int32.min), shifted <= Int64(Int32.max) else { throw JPEGEntropyError.malformed }
                values[base] = Int32(shifted)
            } else if try bits.bit() != 0 { values[base] |= Int32(1 << al) }
            if progressive { return }
        }
        guard let ac else { throw JPEGEntropyError.malformed }
        var k = max(ss, 1)
        if ah == 0 {
            if eobRun > 0 { eobRun -= 1; return }
            while k <= se {
                let token = try ac.symbol(&bits), run = Int(token >> 4), size = Int(token & 15)
                if size == 0 {
                    if run == 15 {
                        guard k + 16 <= se + 1 else { throw JPEGEntropyError.malformed }
                        k += 16; continue
                    }
                    if progressive { eobRun = (1 << run) + (try bits.bits(run)) - 1 }
                    else if run != 0 { throw JPEGEntropyError.malformed }
                    break
                }
                k += run
                guard k <= se, size <= 10 else { throw JPEGEntropyError.malformed }
                values[base + JPEGZigZag.order[k]] = try bits.magnitude(size) * Int32(1 << al)
                k += 1
            }
            return
        }
        let step = Int32(1 << al)
        if eobRun == 0 {
            while k <= se {
                let token = try ac.symbol(&bits)
                var run = Int(token >> 4)
                let size = Int(token & 15)
                guard size <= 1 else { throw JPEGEntropyError.malformed }
                var newValue: Int32 = 0
                if size == 1 { newValue = try bits.bit() == 1 ? step : -step }
                else if run != 15 {
                    eobRun = (1 << run) + (try bits.bits(run)); break
                }
                var landed = false
                while k <= se {
                    let index = base + JPEGZigZag.order[k]
                    if values[index] != 0 { try refine(&values[index], step: step, bits: &bits) }
                    else { run -= 1; if run < 0 { landed = true; break } }
                    k += 1
                }
                guard landed else { throw JPEGEntropyError.malformed }
                if newValue != 0 { values[base + JPEGZigZag.order[k]] = newValue }
                k += 1
            }
        }
        if eobRun > 0 {
            while k <= se { try refine(&values[base + JPEGZigZag.order[k]], step: step, bits: &bits); k += 1 }
            eobRun -= 1
        }
    }

    private static func refine(_ value: inout Int32, step: Int32, bits: inout JPEGEntropyReader) throws {
        guard value != 0 else { return }
        if try bits.bit() != 0 && value & step == 0 {
            let (next, overflow) = value.addingReportingOverflow(value > 0 ? step : -step)
            guard !overflow else { throw JPEGEntropyError.malformed }
            value = next
        }
    }
}
