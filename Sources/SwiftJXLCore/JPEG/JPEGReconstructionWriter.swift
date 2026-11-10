// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Resource and execution limits for byte-exact JPEG bitstream reconstruction.
package struct JPEGReconstructionPolicy: Sendable {
    package let maximumOutputBytes: Int
    package let maximumCoefficientBytes: Int
    package let maximumMemoryBytes: Int
    package let maximumBufferedRefinementBits: Int
    package let deadline: ContinuousClock.Instant
    package let checkpoint: @Sendable () throws -> Void

    package init(
        maximumOutputBytes: Int = 64 * 1024 * 1024,
        maximumCoefficientBytes: Int = 64 * 1024 * 1024,
        maximumMemoryBytes: Int = 128 * 1024 * 1024,
        maximumBufferedRefinementBits: Int = 4 * 1024 * 1024,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(30)),
        checkpoint: @escaping @Sendable () throws -> Void = {}
    ) throws {
        guard maximumOutputBytes > 0,
              maximumCoefficientBytes > 0,
              maximumMemoryBytes > 0,
              maximumBufferedRefinementBits > 0 else {
            throw JPEGEntropyError.resourceLimit
        }
        self.maximumOutputBytes = min(maximumOutputBytes, 64 * 1024 * 1024)
        self.maximumCoefficientBytes = min(maximumCoefficientBytes, 64 * 1024 * 1024)
        self.maximumMemoryBytes = maximumMemoryBytes
        self.maximumBufferedRefinementBits = min(maximumBufferedRefinementBits, 16 * 1024 * 1024)
        self.deadline = deadline
        self.checkpoint = checkpoint
    }

    @inline(__always)
    func verify() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw JPEGEntropyError.resourceLimit
        }
        try checkpoint()
    }
}

/// Reconstructs a byte-exact ITU-T T.81 JPEG file from quantized DCT coefficients and a resolved `JBRDBox`.
package enum JPEGReconstructionWriter {
    package static func write(
        coefficients: [[Int32]],
        metadata: JBRDBox,
        policy: JPEGReconstructionPolicy = (try! JPEGReconstructionPolicy())
    ) throws -> Data {
        var writer = try ReconstructionState(coefficients: coefficients, metadata: metadata, policy: policy)
        return try writer.build()
    }
}

// MARK: - Internal Reconstruction Engine

private struct CanonicalHuffmanEncoder: Sendable {
    let codes: [UInt16]
    let lengths: [UInt8]

    init(counts: [UInt32], values: [UInt32], isDC: Bool) throws {
        guard counts.count == 17 else {
            throw JPEGEntropyError.malformed
        }
        var adjustedCounts = counts
        var adjustedValues = values
        guard !adjustedValues.isEmpty, adjustedValues.last == 256 else {
            throw JPEGEntropyError.malformed
        }
        adjustedValues.removeLast()

        var lastNonZeroLength = 0
        for len in (1...16).reversed() where adjustedCounts[len] > 0 {
            lastNonZeroLength = len
            break
        }
        guard lastNonZeroLength > 0 else {
            throw JPEGEntropyError.malformed
        }
        adjustedCounts[lastNonZeroLength] -= 1

        var totalSymbols = 0
        for len in 1...16 {
            totalSymbols += Int(adjustedCounts[len])
        }
        guard totalSymbols == adjustedValues.count, totalSymbols <= 256 else {
            throw JPEGEntropyError.malformed
        }

        var codes = [UInt16](repeating: 0, count: 256)
        var lengths = [UInt8](repeating: 0, count: 256)
        var seen = [Bool](repeating: false, count: 256)
        var code: UInt32 = 0
        var symIdx = 0

        for len in 1...16 {
            let count = Int(adjustedCounts[len])
            for _ in 0..<count {
                let sym = Int(adjustedValues[symIdx])
                symIdx += 1
                guard sym >= 0, sym < 256, !seen[sym] else {
                    throw JPEGEntropyError.malformed
                }
                if isDC && sym > 15 {
                    throw JPEGEntropyError.malformed
                }
                guard code < (1 << len) else {
                    throw JPEGEntropyError.malformed
                }
                seen[sym] = true
                codes[sym] = UInt16(code)
                lengths[sym] = UInt8(len)
                code += 1
            }
            code <<= 1
        }

        self.codes = codes
        self.lengths = lengths
    }

    @inline(__always)
    func encodeSymbol(_ symbol: UInt8) throws -> (code: UInt16, length: Int) {
        let idx = Int(symbol)
        let len = Int(lengths[idx])
        guard len > 0 else {
            throw JPEGEntropyError.malformed
        }
        return (codes[idx], len)
    }
}

private struct ReconstructionState {
    let coefficients: [[Int32]]
    let metadata: JBRDBox
    let policy: JPEGReconstructionPolicy

    private var reservedMemory: Int = 0
    private var output: [UInt8] = []
    private var bitBuffer: UInt32 = 0
    private var bitCount: Int = 0
    private var paddingCursor: Int = 0

    private var dcTables: [CanonicalHuffmanEncoder?] = [nil, nil, nil, nil]
    private var acTables: [CanonicalHuffmanEncoder?] = [nil, nil, nil, nil]

    private let maxH: Int
    private let maxV: Int
    private let mcusWide: Int
    private let mcusHigh: Int
    private let rawBlocksWide: [Int]
    private let rawBlocksHigh: [Int]
    private let paddedBlocksWide: [Int]
    private let paddedBlocksHigh: [Int]

    init(coefficients: [[Int32]], metadata: JBRDBox, policy: JPEGReconstructionPolicy) throws {
        try policy.verify()
        self.coefficients = coefficients
        self.metadata = metadata
        self.policy = policy

        guard metadata.width > 0, metadata.width <= 65535,
              metadata.height > 0, metadata.height <= 65535,
              coefficients.count == metadata.components.count,
              metadata.components.count == 1 || metadata.components.count == 3,
              !metadata.quant.isEmpty, metadata.quant.count <= 4 else {
            throw JPEGEntropyError.malformed
        }

        if !metadata.hasZeroPaddingBit && !metadata.paddingBits.isEmpty {
            throw JPEGEntropyError.malformed
        }
        if metadata.hasZeroPaddingBit {
            for b in metadata.paddingBits where b > 1 {
                throw JPEGEntropyError.malformed
            }
        }

        var maxHSamp = 0
        var maxVSamp = 0
        for comp in metadata.components {
            guard (1...4).contains(comp.hSampFactor),
                  (1...4).contains(comp.vSampFactor),
                  Int(comp.quantIdx) < metadata.quant.count else {
                throw JPEGEntropyError.malformed
            }
            maxHSamp = max(maxHSamp, comp.hSampFactor)
            maxVSamp = max(maxVSamp, comp.vSampFactor)
        }
        guard maxHSamp > 0, maxVSamp > 0 else {
            throw JPEGEntropyError.malformed
        }
        self.maxH = maxHSamp
        self.maxV = maxVSamp
        self.mcusWide = (metadata.width + maxHSamp * 8 - 1) / (maxHSamp * 8)
        self.mcusHigh = (metadata.height + maxVSamp * 8 - 1) / (maxVSamp * 8)

        var rawW: [Int] = []
        var rawH: [Int] = []
        var padW: [Int] = []
        var padH: [Int] = []
        var totalCoeffBytes = 0

        for (c, comp) in metadata.components.enumerated() {
            let cw = (metadata.width * comp.hSampFactor + maxHSamp - 1) / maxHSamp
            let ch = (metadata.height * comp.vSampFactor + maxVSamp - 1) / maxVSamp
            let rbw = (cw + 7) / 8
            let rbh = (ch + 7) / 8
            let pbw = mcusWide * comp.hSampFactor
            let pbh = mcusHigh * comp.vSampFactor

            guard Int(comp.widthInBlocks) == pbw,
                  Int(comp.heightInBlocks) == pbh else {
                throw JPEGEntropyError.malformed
            }
            let expectedCoeffs = try ScalarOperationBudget.product(
                ScalarOperationBudget.product(pbw, pbh),
                64
            )
            guard coefficients[c].count == expectedCoeffs else {
                throw JPEGEntropyError.malformed
            }
            let planeBytes = try ScalarOperationBudget.product(expectedCoeffs, MemoryLayout<Int32>.stride)
            totalCoeffBytes = try ScalarOperationBudget.sum(totalCoeffBytes, planeBytes)
            guard totalCoeffBytes <= policy.maximumCoefficientBytes else {
                throw JPEGEntropyError.resourceLimit
            }

            for v in coefficients[c] {
                guard (-32767...32767).contains(v) else {
                    throw JPEGEntropyError.malformed
                }
            }

            rawW.append(rbw)
            rawH.append(rbh)
            padW.append(pbw)
            padH.append(pbh)
        }

        self.rawBlocksWide = rawW
        self.rawBlocksHigh = rawH
        self.paddedBlocksWide = padW
        self.paddedBlocksHigh = padH

        try reserveMemory(totalCoeffBytes)

        for q in metadata.quant {
            guard q.precision <= 1, q.index < 4, q.values.count == 64 else {
                throw JPEGEntropyError.malformed
            }
            let maxQ: Int32 = q.precision == 0 ? 255 : 65535
            for v in q.values {
                guard (1...maxQ).contains(v) else {
                    throw JPEGEntropyError.malformed
                }
            }
        }
    }

    private mutating func reserveMemory(_ bytes: Int) throws {
        guard bytes >= 0, bytes <= policy.maximumMemoryBytes - reservedMemory else {
            throw JPEGEntropyError.resourceLimit
        }
        reservedMemory += bytes
    }

    @inline(__always)
    private mutating func appendByte(_ byte: UInt8) throws {
        guard output.count < policy.maximumOutputBytes else {
            throw JPEGEntropyError.resourceLimit
        }
        output.append(byte)
    }

    private mutating func appendBytes<S: Sequence>(_ bytes: S) throws where S.Element == UInt8 {
        for b in bytes {
            try appendByte(b)
        }
    }

    private mutating func appendData(_ data: Data) throws {
        guard data.count <= policy.maximumOutputBytes - output.count else {
            throw JPEGEntropyError.resourceLimit
        }
        var offset = 0
        while offset < data.count {
            try policy.verify()
            let end = min(data.count, offset + 4096)
            output.append(contentsOf: data[(data.startIndex + offset)..<(data.startIndex + end)])
            offset = end
        }
    }

    @inline(__always)
    private mutating func writeBits(_ value: UInt32, count: Int) throws {
        guard count > 0 else { return }
        let mask: UInt32 = count == 32 ? UInt32.max : ((1 << count) - 1)
        bitBuffer = (bitBuffer << count) | (value & mask)
        bitCount += count
        while bitCount >= 8 {
            bitCount -= 8
            let byte = UInt8(truncatingIfNeeded: bitBuffer >> bitCount)
            try appendByte(byte)
            if byte == 0xFF {
                try appendByte(0x00)
            }
        }
    }

    @inline(__always)
    private mutating func writeBit(_ bit: UInt8) throws {
        try writeBits(UInt32(bit & 1), count: 1)
    }

    @inline(__always)
    private mutating func writeHuffman(_ symbol: UInt8, table: CanonicalHuffmanEncoder) throws {
        let encoded = try table.encodeSymbol(symbol)
        try writeBits(UInt32(encoded.code), count: encoded.length)
    }

    private mutating func flushEntropyPadding() throws {
        while (bitCount & 7) != 0 {
            if metadata.hasZeroPaddingBit {
                guard paddingCursor < metadata.paddingBits.count else {
                    throw JPEGEntropyError.malformed
                }
                let bit = metadata.paddingBits[paddingCursor]
                paddingCursor += 1
                try writeBit(bit)
            } else {
                try writeBit(1)
            }
        }
        bitBuffer = 0
        bitCount = 0
    }

    mutating func build() throws -> Data {
        try policy.verify()
        guard !metadata.markerOrder.isEmpty,
              metadata.markerOrder.last == 0xD9 else {
            throw JPEGEntropyError.malformed
        }

        // Emit SOI
        try appendByte(0xFF)
        try appendByte(0xD8)

        var appIdx = 0
        var comIdx = 0
        var interIdx = 0
        var quantIdx = 0
        var huffIdx = 0
        var scanIdx = 0
        var sawSOF = false
        var sofMarker: UInt8 = 0

        for (mPos, marker) in metadata.markerOrder.enumerated() {
            try policy.verify()
            if marker == 0xD9 && mPos != metadata.markerOrder.count - 1 {
                throw JPEGEntropyError.malformed
            }

            switch marker {
            case 0xE0...0xEF:
                guard appIdx < metadata.appData.count else {
                    throw JPEGEntropyError.malformed
                }
                let data = metadata.appData[appIdx]
                appIdx += 1
                guard data.count >= 3,
                      data[data.startIndex] == marker,
                      Int(data[data.startIndex + 1]) * 256 + Int(data[data.startIndex + 2]) + 1 == data.count else {
                    throw JPEGEntropyError.malformed
                }
                try appendByte(0xFF)
                try appendData(data)

            case 0xFE:
                guard comIdx < metadata.comData.count else {
                    throw JPEGEntropyError.malformed
                }
                let data = metadata.comData[comIdx]
                comIdx += 1
                guard data.count >= 3,
                      data[data.startIndex] == 0xFE,
                      Int(data[data.startIndex + 1]) * 256 + Int(data[data.startIndex + 2]) + 1 == data.count else {
                    throw JPEGEntropyError.malformed
                }
                try appendByte(0xFF)
                try appendData(data)

            case 0xFF:
                guard interIdx < metadata.interMarkerData.count else {
                    throw JPEGEntropyError.malformed
                }
                let data = metadata.interMarkerData[interIdx]
                interIdx += 1
                try appendData(data)

            case 0xDB:
                try emitDQT(quantIdx: &quantIdx)

            case 0xC4:
                try emitDHT(huffIdx: &huffIdx)

            case 0xC0...0xC2:
                guard !sawSOF else {
                    throw JPEGEntropyError.malformed
                }
                sawSOF = true
                sofMarker = marker
                try emitSOF(marker: marker)

            case 0xDD:
                guard metadata.restartInterval <= 65535 else {
                    throw JPEGEntropyError.malformed
                }
                try appendBytes([
                    0xFF, 0xDD, 0x00, 0x04,
                    UInt8(truncatingIfNeeded: metadata.restartInterval >> 8),
                    UInt8(truncatingIfNeeded: metadata.restartInterval)
                ])

            case 0xDA:
                guard sawSOF, scanIdx < metadata.scanInfo.count else {
                    throw JPEGEntropyError.malformed
                }
                let scan = metadata.scanInfo[scanIdx]
                scanIdx += 1
                try emitSOSAndEntropy(scan: scan, sofMarker: sofMarker)

            case 0xD9:
                guard sawSOF else {
                    throw JPEGEntropyError.malformed
                }
                try appendBytes([0xFF, 0xD9])

            default:
                throw JPEGEntropyError.malformed
            }
        }

        guard appIdx == metadata.appData.count,
              comIdx == metadata.comData.count,
              interIdx == metadata.interMarkerData.count,
              quantIdx == metadata.quant.count,
              huffIdx == metadata.huffmanCode.count,
              scanIdx == metadata.scanInfo.count else {
            throw JPEGEntropyError.malformed
        }
        if metadata.hasZeroPaddingBit {
            guard paddingCursor == metadata.paddingBits.count else {
                throw JPEGEntropyError.malformed
            }
        }

        if !metadata.tailData.isEmpty {
            try appendData(metadata.tailData)
        }

        try reserveMemory(output.count)
        try policy.verify()
        return Data(output)
    }

    private mutating func emitDQT(quantIdx: inout Int) throws {
        guard quantIdx < metadata.quant.count else {
            throw JPEGEntropyError.malformed
        }
        var payload: [UInt8] = []
        while quantIdx < metadata.quant.count {
            let table = metadata.quant[quantIdx]
            quantIdx += 1
            let info = UInt8(((table.precision & 0x0F) << 4) | (table.index & 0x0F))
            payload.append(info)
            for z in 0..<64 {
                let v = table.values[JPEGZigZag.order[z]]
                if table.precision == 0 {
                    guard (1...255).contains(v) else {
                        throw JPEGEntropyError.malformed
                    }
                    payload.append(UInt8(truncatingIfNeeded: v))
                } else {
                    guard (1...65535).contains(v) else {
                        throw JPEGEntropyError.malformed
                    }
                    payload.append(UInt8(truncatingIfNeeded: v >> 8))
                    payload.append(UInt8(truncatingIfNeeded: v))
                }
            }
            if table.isLast { break }
        }
        let length = payload.count + 2
        guard length <= 65535 else {
            throw JPEGEntropyError.malformed
        }
        try appendBytes([
            0xFF, 0xDB,
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length)
        ])
        try appendBytes(payload)
    }

    private mutating func emitDHT(huffIdx: inout Int) throws {
        guard huffIdx < metadata.huffmanCode.count else {
            throw JPEGEntropyError.malformed
        }
        var payload: [UInt8] = []
        while huffIdx < metadata.huffmanCode.count {
            let hc = metadata.huffmanCode[huffIdx]
            huffIdx += 1
            let isAC = (hc.slotId & 0x10) != 0
            let tableSlot = hc.slotId & 0x0F
            guard (hc.slotId & ~0x13) == 0, tableSlot < 4 else {
                throw JPEGEntropyError.malformed
            }

            let encoder = try CanonicalHuffmanEncoder(counts: hc.counts, values: hc.values, isDC: !isAC)
            if isAC {
                acTables[tableSlot] = encoder
            } else {
                dcTables[tableSlot] = encoder
            }

            var adjustedCounts = hc.counts
            for len in (1...16).reversed() where adjustedCounts[len] > 0 {
                adjustedCounts[len] -= 1
                break
            }
            payload.append(UInt8(truncatingIfNeeded: hc.slotId))
            for len in 1...16 {
                payload.append(UInt8(truncatingIfNeeded: adjustedCounts[len]))
            }
            for v in hc.values.dropLast() {
                payload.append(UInt8(truncatingIfNeeded: v))
            }
            if hc.isLast { break }
        }
        let length = payload.count + 2
        guard length <= 65535 else {
            throw JPEGEntropyError.malformed
        }
        try appendBytes([
            0xFF, 0xC4,
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length)
        ])
        try appendBytes(payload)
    }

    private mutating func emitSOF(marker: UInt8) throws {
        let nComp = metadata.components.count
        let length = 8 + 3 * nComp
        try appendBytes([
            0xFF, marker,
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
            8,
            UInt8(truncatingIfNeeded: metadata.height >> 8),
            UInt8(truncatingIfNeeded: metadata.height),
            UInt8(truncatingIfNeeded: metadata.width >> 8),
            UInt8(truncatingIfNeeded: metadata.width),
            UInt8(truncatingIfNeeded: nComp)
        ])
        for comp in metadata.components {
            guard Int(comp.quantIdx) < metadata.quant.count else {
                throw JPEGEntropyError.malformed
            }
            let qSlot = metadata.quant[Int(comp.quantIdx)].index
            try appendBytes([
                UInt8(truncatingIfNeeded: comp.id),
                UInt8(truncatingIfNeeded: (comp.hSampFactor << 4) | comp.vSampFactor),
                UInt8(truncatingIfNeeded: qSlot)
            ])
        }
    }

    private mutating func emitSOSAndEntropy(scan: JBRDScanInfo, sofMarker: UInt8) throws {
        let ns = Int(scan.numComponents)
        guard ns == scan.components.count, (1...3).contains(ns), ns <= metadata.components.count else {
            throw JPEGEntropyError.malformed
        }
        let ss = Int(scan.ss)
        let se = Int(scan.se)
        let ah = Int(scan.ah)
        let al = Int(scan.al)

        guard (0...63).contains(ss), (ss...63).contains(se),
              (0...13).contains(ah), (0...13).contains(al) else {
            throw JPEGEntropyError.malformed
        }
        if sofMarker == 0xC0 || sofMarker == 0xC1 {
            guard ss == 0, se == 63, ah == 0, al == 0 else {
                throw JPEGEntropyError.malformed
            }
        } else {
            if ss == 0 {
                guard se == 0 else { throw JPEGEntropyError.malformed }
            } else {
                guard ns == 1 else { throw JPEGEntropyError.malformed }
            }
            if ah > 0 {
                guard ah == al + 1 else { throw JPEGEntropyError.malformed }
            }
        }

        let sosLength = 6 + 2 * ns
        try appendBytes([
            0xFF, 0xDA,
            UInt8(truncatingIfNeeded: sosLength >> 8),
            UInt8(truncatingIfNeeded: sosLength),
            UInt8(truncatingIfNeeded: ns)
        ])

        var seenComp = Set<Int>()
        for sc in scan.components {
            let cIdx = Int(sc.compIdx)
            guard cIdx >= 0, cIdx < metadata.components.count,
                  seenComp.insert(cIdx).inserted,
                  sc.dcTblIdx < 4, sc.acTblIdx < 4 else {
                throw JPEGEntropyError.malformed
            }
            try appendBytes([
                UInt8(truncatingIfNeeded: metadata.components[cIdx].id),
                UInt8(truncatingIfNeeded: (sc.dcTblIdx << 4) | sc.acTblIdx)
            ])
        }
        try appendBytes([
            UInt8(truncatingIfNeeded: ss),
            UInt8(truncatingIfNeeded: se),
            UInt8(truncatingIfNeeded: (ah << 4) | al)
        ])

        // Determine scan MCU geometry and total block count
        let scanMCUsWide: Int
        let scanMCUsHigh: Int
        let blocksPerMCU: Int
        if ns == 1 {
            let cIdx = Int(scan.components[0].compIdx)
            scanMCUsWide = rawBlocksWide[cIdx]
            scanMCUsHigh = rawBlocksHigh[cIdx]
            blocksPerMCU = 1
        } else {
            scanMCUsWide = mcusWide
            scanMCUsHigh = mcusHigh
            blocksPerMCU = scan.components.reduce(0) {
                let c = Int($1.compIdx)
                return $0 + metadata.components[c].hSampFactor * metadata.components[c].vSampFactor
            }
            guard blocksPerMCU <= 10 else {
                throw JPEGEntropyError.malformed
            }
        }
        let totalMCUs = scanMCUsWide * scanMCUsHigh
        let totalScanBlocks = totalMCUs * blocksPerMCU

        // Validate resetPoints and extraZeroRuns block indices
        for rp in scan.resetPoints {
            guard Int(rp) < totalScanBlocks else {
                throw JPEGEntropyError.malformed
            }
        }
        for zr in scan.extraZeroRuns {
            guard Int(zr.blockIdx) < totalScanBlocks, zr.numExtraZeroRuns > 0 else {
                throw JPEGEntropyError.malformed
            }
        }

        if ss == 0 && se == 63 {
            try encodeSequentialScan(
                scan: scan,
                sofMarker: sofMarker,
                scanMCUsWide: scanMCUsWide,
                scanMCUsHigh: scanMCUsHigh
            )
        } else if ss == 0 {
            try encodeProgressiveDCScan(
                scan: scan,
                ah: ah,
                al: al,
                scanMCUsWide: scanMCUsWide,
                scanMCUsHigh: scanMCUsHigh
            )
        } else {
            try encodeProgressiveACScan(
                scan: scan,
                ss: ss,
                se: se,
                ah: ah,
                al: al,
                scanMCUsWide: scanMCUsWide,
                scanMCUsHigh: scanMCUsHigh
            )
        }

        try flushEntropyPadding()
    }

    @inline(__always)
    private static func magnitudeCategoryAndBits(_ value: Int32) -> (category: Int, bits: UInt32) {
        if value == 0 { return (0, 0) }
        let absVal = UInt32( value < 0 ? -Int(value) : Int(value) )
        let category = 32 - absVal.leadingZeroBitCount
        let bits: UInt32
        if value > 0 {
            bits = absVal
        } else {
            bits = (absVal ^ ((1 << category) - 1))
        }
        return (category, bits)
    }

    private mutating func encodeSequentialScan(
        scan: JBRDScanInfo,
        sofMarker: UInt8,
        scanMCUsWide: Int,
        scanMCUsHigh: Int
    ) throws {
        let ns = scan.components.count
        let maxCat = sofMarker == 0xC0 ? 10 : 11
        let maxDC = sofMarker == 0xC0 ? 11 : 12
        var lastDC = [Int32](repeating: 0, count: metadata.components.count)
        let restartInterval = Int(metadata.restartInterval)
        var mcusSinceRestart = 0
        var rstIdx = 0
        var blockIdx: UInt32 = 0
        var extraZeroCursor = 0

        for mcuY in 0..<scanMCUsHigh {
            try policy.verify()
            for mcuX in 0..<scanMCUsWide {
                if restartInterval > 0 && mcusSinceRestart == restartInterval {
                    try flushEntropyPadding()
                    try appendBytes([0xFF, 0xD0 + UInt8(rstIdx & 7)])
                    rstIdx += 1
                    mcusSinceRestart = 0
                    lastDC = [Int32](repeating: 0, count: metadata.components.count)
                }

                for sc in scan.components {
                    let cIdx = Int(sc.compIdx)
                    guard let dcTable = dcTables[Int(sc.dcTblIdx)],
                          let acTable = acTables[Int(sc.acTblIdx)] else {
                        throw JPEGEntropyError.malformed
                    }
                    let hSamp = ns == 1 ? 1 : metadata.components[cIdx].hSampFactor
                    let vSamp = ns == 1 ? 1 : metadata.components[cIdx].vSampFactor
                    let stride = paddedBlocksWide[cIdx]

                    for v in 0..<vSamp {
                        let by = mcuY * vSamp + v
                        for h in 0..<hSamp {
                            let bx = mcuX * hSamp + h
                            let blockBase = (by * stride + bx) * 64

                            // DC coefficient
                            let dcVal = coefficients[cIdx][blockBase]
                            let diff = dcVal - lastDC[cIdx]
                            lastDC[cIdx] = dcVal
                            let (dcCat, dcBits) = Self.magnitudeCategoryAndBits(diff)
                            guard dcCat <= maxDC else {
                                throw JPEGEntropyError.malformed
                            }
                            try writeHuffman(UInt8(dcCat), table: dcTable)
                            if dcCat > 0 {
                                try writeBits(dcBits, count: dcCat)
                            }

                            // AC coefficients
                            var lastNZ = 0
                            for k in (1...63).reversed() {
                                if coefficients[cIdx][blockBase + JPEGZigZag.order[k]] != 0 {
                                    lastNZ = k
                                    break
                                }
                            }

                            var run = 0
                            if lastNZ > 0 {
                                for k in 1...lastNZ {
                                    let acVal = coefficients[cIdx][blockBase + JPEGZigZag.order[k]]
                                    if acVal == 0 {
                                        run += 1
                                    } else {
                                        while run >= 16 {
                                            try writeHuffman(0xF0, table: acTable)
                                            run -= 16
                                        }
                                        let (acCat, acBits) = Self.magnitudeCategoryAndBits(acVal)
                                        guard acCat <= maxCat else {
                                            throw JPEGEntropyError.malformed
                                        }
                                        let sym = UInt8((run << 4) | acCat)
                                        try writeHuffman(sym, table: acTable)
                                        try writeBits(acBits, count: acCat)
                                        run = 0
                                    }
                                }
                            }

                            var extraZRL = 0
                            if extraZeroCursor < scan.extraZeroRuns.count,
                               scan.extraZeroRuns[extraZeroCursor].blockIdx == blockIdx {
                                extraZRL = Int(scan.extraZeroRuns[extraZeroCursor].numExtraZeroRuns)
                                extraZeroCursor += 1
                            }

                            if extraZRL > 0 {
                                guard lastNZ + 16 * extraZRL <= 63 else {
                                    throw JPEGEntropyError.malformed
                                }
                                for _ in 0..<extraZRL {
                                    try writeHuffman(0xF0, table: acTable)
                                }
                            }

                            if lastNZ + 16 * extraZRL < 63 {
                                try writeHuffman(0x00, table: acTable)
                            }

                            blockIdx += 1
                        }
                    }
                }
                mcusSinceRestart += 1
            }
        }

        guard scan.resetPoints.isEmpty, extraZeroCursor == scan.extraZeroRuns.count else {
            throw JPEGEntropyError.malformed
        }
    }

    private mutating func encodeProgressiveDCScan(
        scan: JBRDScanInfo,
        ah: Int,
        al: Int,
        scanMCUsWide: Int,
        scanMCUsHigh: Int
    ) throws {
        guard scan.resetPoints.isEmpty, scan.extraZeroRuns.isEmpty else {
            throw JPEGEntropyError.malformed
        }
        let ns = scan.components.count
        var lastDC = [Int32](repeating: 0, count: metadata.components.count)
        let restartInterval = Int(metadata.restartInterval)
        var mcusSinceRestart = 0
        var rstIdx = 0

        for mcuY in 0..<scanMCUsHigh {
            try policy.verify()
            for mcuX in 0..<scanMCUsWide {
                if restartInterval > 0 && mcusSinceRestart == restartInterval {
                    try flushEntropyPadding()
                    try appendBytes([0xFF, 0xD0 + UInt8(rstIdx & 7)])
                    rstIdx += 1
                    mcusSinceRestart = 0
                    lastDC = [Int32](repeating: 0, count: metadata.components.count)
                }

                for sc in scan.components {
                    let cIdx = Int(sc.compIdx)
                    let hSamp = ns == 1 ? 1 : metadata.components[cIdx].hSampFactor
                    let vSamp = ns == 1 ? 1 : metadata.components[cIdx].vSampFactor
                    let stride = paddedBlocksWide[cIdx]

                    for v in 0..<vSamp {
                        let by = mcuY * vSamp + v
                        for h in 0..<hSamp {
                            let bx = mcuX * hSamp + h
                            let blockBase = (by * stride + bx) * 64
                            let rawDC = coefficients[cIdx][blockBase]

                            if ah == 0 {
                                guard let dcTable = dcTables[Int(sc.dcTblIdx)] else {
                                    throw JPEGEntropyError.malformed
                                }
                                let shiftedDC = rawDC >> al
                                let diff = shiftedDC - lastDC[cIdx]
                                lastDC[cIdx] = shiftedDC
                                let (dcCat, dcBits) = Self.magnitudeCategoryAndBits(diff)
                                guard dcCat <= 11 else {
                                    throw JPEGEntropyError.malformed
                                }
                                try writeHuffman(UInt8(dcCat), table: dcTable)
                                if dcCat > 0 {
                                    try writeBits(dcBits, count: dcCat)
                                }
                            } else {
                                let bit = UInt8(truncatingIfNeeded: (rawDC >> al) & 1)
                                try writeBit(bit)
                            }
                        }
                    }
                }
                mcusSinceRestart += 1
            }
        }
    }

    private mutating func encodeProgressiveACScan(
        scan: JBRDScanInfo,
        ss: Int,
        se: Int,
        ah: Int,
        al: Int,
        scanMCUsWide: Int,
        scanMCUsHigh: Int
    ) throws {
        let sc = scan.components[0]
        let cIdx = Int(sc.compIdx)
        guard let acTable = acTables[Int(sc.acTblIdx)] else {
            throw JPEGEntropyError.malformed
        }
        if ah > 0 && !scan.extraZeroRuns.isEmpty {
            throw JPEGEntropyError.unsupported
        }

        let stride = paddedBlocksWide[cIdx]
        let restartInterval = Int(metadata.restartInterval)
        var mcusSinceRestart = 0
        var rstIdx = 0
        var blockIdx: UInt32 = 0
        var resetCursor = 0
        var extraZeroCursor = 0

        var eobRun = 0
        var eobRefinementBits: [UInt8] = []
        var blockRefinementBits: [UInt8] = []
        var trailingRefinementBits: [UInt8] = []

        func flushEOB() throws {
            guard eobRun > 0 else { return }
            let n = Int.bitWidth - eobRun.leadingZeroBitCount - 1
            guard (0...14).contains(n) else {
                throw JPEGEntropyError.malformed
            }
            let sym = UInt8(n << 4)
            try writeHuffman(sym, table: acTable)
            if n > 0 {
                let extra = UInt32(eobRun & ((1 << n) - 1))
                try writeBits(extra, count: n)
            }
            for bit in eobRefinementBits {
                try writeBit(bit)
            }
            eobRun = 0
            eobRefinementBits.removeAll(keepingCapacity: true)
        }

        for by in 0..<scanMCUsHigh {
            try policy.verify()
            for bx in 0..<scanMCUsWide {
                if restartInterval > 0 && mcusSinceRestart == restartInterval {
                    try flushEOB()
                    try flushEntropyPadding()
                    try appendBytes([0xFF, 0xD0 + UInt8(rstIdx & 7)])
                    rstIdx += 1
                    mcusSinceRestart = 0
                }

                if resetCursor < scan.resetPoints.count,
                   scan.resetPoints[resetCursor] == blockIdx {
                    try flushEOB()
                    resetCursor += 1
                }

                var extraZRL = 0
                if extraZeroCursor < scan.extraZeroRuns.count,
                   scan.extraZeroRuns[extraZeroCursor].blockIdx == blockIdx {
                    extraZRL = Int(scan.extraZeroRuns[extraZeroCursor].numExtraZeroRuns)
                    extraZeroCursor += 1
                }

                let blockBase = (by * stride + bx) * 64

                if ah == 0 {
                    var lastNZ = ss - 1
                    for k in (ss...se).reversed() {
                        let c = coefficients[cIdx][blockBase + JPEGZigZag.order[k]]
                        let mag = abs(Int(c)) >> al
                        if mag != 0 {
                            lastNZ = k
                            break
                        }
                    }

                    var run = 0
                    if lastNZ >= ss {
                        for k in ss...lastNZ {
                            let c = coefficients[cIdx][blockBase + JPEGZigZag.order[k]]
                            let mag = abs(Int(c)) >> al
                            if mag == 0 {
                                run += 1
                            } else {
                                try flushEOB()
                                while run >= 16 {
                                    try writeHuffman(0xF0, table: acTable)
                                    run -= 16
                                }
                                let scaled: Int32 = c >= 0 ? Int32(mag) : -Int32(mag)
                                let (acCat, acBits) = Self.magnitudeCategoryAndBits(scaled)
                                guard acCat <= 11 else {
                                    throw JPEGEntropyError.malformed
                                }
                                let sym = UInt8((run << 4) | acCat)
                                try writeHuffman(sym, table: acTable)
                                try writeBits(acBits, count: acCat)
                                run = 0
                            }
                        }
                    }

                    if extraZRL > 0 {
                        guard lastNZ + 16 * extraZRL <= se else {
                            throw JPEGEntropyError.malformed
                        }
                        try flushEOB()
                        for _ in 0..<extraZRL {
                            try writeHuffman(0xF0, table: acTable)
                        }
                    }

                    if lastNZ + 16 * extraZRL < se {
                        eobRun += 1
                        if eobRun == 0x7FFF {
                            try flushEOB()
                        }
                    }
                } else {
                    blockRefinementBits.removeAll(keepingCapacity: true)
                    trailingRefinementBits.removeAll(keepingCapacity: true)

                    var lastNewNZ = ss - 1
                    for k in ss...se {
                        let c = coefficients[cIdx][blockBase + JPEGZigZag.order[k]]
                        let absC = abs(Int(c))
                        if (absC >> ah) == 0 {
                            if (absC >> (al + 1)) != 0 {
                                throw JPEGEntropyError.malformed
                            }
                            if ((absC >> al) & 1) != 0 {
                                lastNewNZ = k
                            }
                        }
                    }

                    var run = 0
                    for k in ss...se {
                        let c = coefficients[cIdx][blockBase + JPEGZigZag.order[k]]
                        let absC = abs(Int(c))
                        if (absC >> ah) != 0 {
                            let refBit = UInt8((absC >> al) & 1)
                            if k <= lastNewNZ {
                                blockRefinementBits.append(refBit)
                            } else {
                                trailingRefinementBits.append(refBit)
                            }
                        } else if k <= lastNewNZ {
                            if ((absC >> al) & 1) == 0 {
                                run += 1
                                if run == 16 {
                                    try flushEOB()
                                    try writeHuffman(0xF0, table: acTable)
                                    for b in blockRefinementBits {
                                        try writeBit(b)
                                    }
                                    blockRefinementBits.removeAll(keepingCapacity: true)
                                    run = 0
                                }
                            } else {
                                try flushEOB()
                                let sym = UInt8((run << 4) | 1)
                                try writeHuffman(sym, table: acTable)
                                try writeBit(c > 0 ? 1 : 0)
                                for b in blockRefinementBits {
                                    try writeBit(b)
                                }
                                blockRefinementBits.removeAll(keepingCapacity: true)
                                run = 0
                            }
                        }
                    }

                    if lastNewNZ < se {
                        guard eobRefinementBits.count + trailingRefinementBits.count <= policy.maximumBufferedRefinementBits else {
                            throw JPEGEntropyError.resourceLimit
                        }
                        eobRun += 1
                        eobRefinementBits.append(contentsOf: trailingRefinementBits)
                        if eobRun == 0x7FFF {
                            try flushEOB()
                        }
                    }
                }

                blockIdx += 1
                mcusSinceRestart += 1
            }
        }

        try flushEOB()
        guard resetCursor == scan.resetPoints.count,
              extraZeroCursor == scan.extraZeroRuns.count else {
            throw JPEGEntropyError.malformed
        }
    }
}
