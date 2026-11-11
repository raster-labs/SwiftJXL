// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Resource, cancellation, and profile policy for ITU-T T.81 DCT coefficient decoding.
package struct JPEGCoefficientPolicy: Sendable {
    package let pixelProfile: Bool
    package let maximumInputBytes: Int
    package let maximumCoefficientBytes: Int
    package let maximumMemoryBytes: Int
    package let maximumPaddingRecords: Int
    package let maximumScanEvents: Int
    package let deadline: ContinuousClock.Instant
    package let checkpointClosure: @Sendable () throws -> Void

    package init(
        pixelProfile: Bool = false,
        maximumInputBytes: Int = 64 * 1024 * 1024,
        maximumCoefficientBytes: Int = 64 * 1024 * 1024,
        maximumMemoryBytes: Int = 128 * 1024 * 1024,
        maximumPaddingRecords: Int = 65536,
        maximumScanEvents: Int = 65536,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(10)),
        checkpoint: @escaping @Sendable () throws -> Void = {}
    ) throws {
        guard maximumInputBytes > 0,
              maximumCoefficientBytes > 0,
              maximumMemoryBytes > 0,
              (1...65536).contains(maximumPaddingRecords),
              (1...65536).contains(maximumScanEvents) else {
            throw JPEGEntropyError.resourceLimit
        }
        self.pixelProfile = pixelProfile
        self.maximumInputBytes = maximumInputBytes
        self.maximumCoefficientBytes = maximumCoefficientBytes
        self.maximumMemoryBytes = maximumMemoryBytes
        self.maximumPaddingRecords = maximumPaddingRecords
        self.maximumScanEvents = maximumScanEvents
        self.deadline = deadline
        self.checkpointClosure = checkpoint
    }

    package func checkpoint() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw JPEGEntropyError.resourceLimit
        }
        try checkpointClosure()
    }
}

/// Validated DCT coefficient planes, quantisation tables, scan descriptors, and entropy padding records.
package struct JPEGDecodedCoefficients: Sendable {
    package let source: Data
    package let frame: JPEGFrameLayout
    package let coefficients: [[Int32]]
    package let quantisation: [[UInt16]]
    package let scans: [JBRDScanInfo]
    package let padding: [JPEGEntropyPadding]
}

/// Clean-room ITU-T T.81 sequential and progressive DCT coefficient decoder.
package enum JPEGCoefficientDecoder {
    package static func decode(
        _ data: Data,
        policy: JPEGCoefficientPolicy
    ) throws -> JPEGDecodedCoefficients {
        try policy.checkpoint()
        guard data.count <= policy.maximumInputBytes else {
            throw JPEGEntropyError.resourceLimit
        }

        var segmentReader = try JPEGSegmentReader(
            data,
            maximumInputBytes: policy.maximumInputBytes,
            deadline: policy.deadline,
            checkpoint: { try policy.checkpoint() }
        )

        var frameLayout: JPEGFrameLayout?
        var coefficients: [[Int32]] = []
        var activeQuantTables = [[UInt16]?](repeating: nil, count: 4)
        var componentQuantTables: [[UInt16]?] = []
        var dcTables = [JPEGHuffmanTable?](repeating: nil, count: 4)
        var dcMaxSymbol = [Int](repeating: 0, count: 4)
        var acTables = [JPEGHuffmanTable?](repeating: nil, count: 4)
        var spectralHistory: [[Int]] = []
        var restartInterval = 0
        var scans: [JBRDScanInfo] = []
        var paddingRecords: [JPEGEntropyPadding] = []
        var totalScanEvents = 0
        var sawEOI = false

        func byte(at offset: Int) -> UInt8 {
            data[data.startIndex + offset]
        }

        func appendPadding(_ record: JPEGEntropyPadding) throws {
            guard paddingRecords.count < policy.maximumPaddingRecords else {
                throw JPEGEntropyError.resourceLimit
            }
            paddingRecords.append(record)
        }

        while let segment = try segmentReader.next() {
            try policy.checkpoint()
            let code = segment.markerByte
            switch code {
            case 0xD8:
                continue

            case 0xE0...0xEF, 0xFE:
                continue

            case 0xDB:
                var cursor = segment.payloadRange.lowerBound
                let end = segment.payloadRange.upperBound
                guard cursor < end else { throw JPEGEntropyError.malformed }
                while cursor < end {
                    let info = byte(at: cursor)
                    cursor += 1
                    let precision = Int(info >> 4)
                    let slot = Int(info & 0x0F)
                    guard (0...1).contains(precision), (0...3).contains(slot) else {
                        throw JPEGEntropyError.malformed
                    }
                    let entryBytes = precision == 0 ? 1 : 2
                    guard cursor + 64 * entryBytes <= end else {
                        throw JPEGEntropyError.malformed
                    }
                    var table = [UInt16](repeating: 0, count: 64)
                    for z in 0..<64 {
                        let raw: UInt16
                        if entryBytes == 1 {
                            raw = UInt16(byte(at: cursor))
                            cursor += 1
                        } else {
                            raw = (UInt16(byte(at: cursor)) << 8) | UInt16(byte(at: cursor + 1))
                            cursor += 2
                        }
                        guard raw > 0 else { throw JPEGEntropyError.malformed }
                        table[JPEGZigZag.order[z]] = raw
                    }
                    activeQuantTables[slot] = table
                }

            case 0xC4:
                var cursor = segment.payloadRange.lowerBound
                let end = segment.payloadRange.upperBound
                guard cursor < end else { throw JPEGEntropyError.malformed }
                while cursor < end {
                    let info = byte(at: cursor)
                    cursor += 1
                    let tableClass = Int(info >> 4)
                    let slot = Int(info & 0x0F)
                    guard (0...1).contains(tableClass), (0...3).contains(slot), cursor + 16 <= end else {
                        throw JPEGEntropyError.malformed
                    }
                    var counts = [Int](repeating: 0, count: 16)
                    var totalSymbols = 0
                    for i in 0..<16 {
                        let c = Int(byte(at: cursor + i))
                        counts[i] = c
                        totalSymbols += c
                    }
                    cursor += 16
                    guard totalSymbols > 0, totalSymbols <= 256, cursor + totalSymbols <= end else {
                        throw JPEGEntropyError.malformed
                    }
                    var symbols = [UInt8](repeating: 0, count: totalSymbols)
                    var seen = Set<UInt8>()
                    seen.reserveCapacity(totalSymbols)
                    var maxSym = 0
                    for i in 0..<totalSymbols {
                        let sym = byte(at: cursor + i)
                        guard seen.insert(sym).inserted else {
                            throw JPEGEntropyError.malformed
                        }
                        if Int(sym) > maxSym { maxSym = Int(sym) }
                        symbols[i] = sym
                    }
                    cursor += totalSymbols
                    let allowedDCMax = policy.pixelProfile ? 15 : 11
                    if tableClass == 0 && maxSym > allowedDCMax {
                        throw JPEGEntropyError.malformed
                    }
                    let table = try JPEGHuffmanTable(counts: counts, symbols: symbols)
                    if tableClass == 0 {
                        dcTables[slot] = table
                        dcMaxSymbol[slot] = maxSym
                    } else {
                        acTables[slot] = table
                    }
                }

            case 0xDD:
                guard segment.payloadRange.count == 2 else {
                    throw JPEGEntropyError.malformed
                }
                let start = segment.payloadRange.lowerBound
                restartInterval = (Int(byte(at: start)) << 8) | Int(byte(at: start + 1))

            case 0xC0, 0xC1, 0xC2:
                guard frameLayout == nil else {
                    throw JPEGFrameError.malformed
                }
                let layout = try JPEGFrameLayout(
                    data: data,
                    segment: segment,
                    maximumCoefficientBytes: policy.maximumCoefficientBytes,
                    pixelProfile: policy.pixelProfile
                )
                let (coeffBytes, coeffOverflow) = layout.coefficientCount.multipliedReportingOverflow(
                    by: MemoryLayout<Int32>.stride
                )
                let (withSource, srcOverflow) = coeffBytes.addingReportingOverflow(data.count)
                let (totalMemory, memOverflow) = withSource.addingReportingOverflow(16384)
                guard !coeffOverflow, !srcOverflow, !memOverflow,
                      coeffBytes <= policy.maximumCoefficientBytes,
                      totalMemory <= policy.maximumMemoryBytes else {
                    throw JPEGEntropyError.resourceLimit
                }
                frameLayout = layout
                coefficients = layout.components.map { comp in
                    [Int32](repeating: 0, count: comp.paddedBlocksWide * comp.paddedBlocksHigh * 64)
                }
                componentQuantTables = [[UInt16]?](repeating: nil, count: layout.components.count)
                spectralHistory = layout.components.map { _ in [Int](repeating: -1, count: 64) }

            case 0xDA:
                guard let layout = frameLayout else {
                    throw JPEGEntropyError.malformed
                }
                let payload = segment.payloadRange
                guard payload.count >= 4 else {
                    throw JPEGEntropyError.malformed
                }
                let ns = Int(byte(at: payload.lowerBound))
                guard (1...4).contains(ns),
                      ns <= layout.components.count,
                      payload.count == 4 + 2 * ns else {
                    throw JPEGEntropyError.malformed
                }

                var scanComponents: [JBRDScanComponent] = []
                scanComponents.reserveCapacity(ns)
                var mcuBlocks = 0
                for i in 0..<ns {
                    let selector = byte(at: payload.lowerBound + 1 + 2 * i)
                    let tableByte = byte(at: payload.lowerBound + 2 + 2 * i)
                    let dcIdx = Int(tableByte >> 4)
                    let acIdx = Int(tableByte & 0x0F)
                    guard (0...3).contains(dcIdx), (0...3).contains(acIdx),
                          let compIdx = layout.components.firstIndex(where: { $0.id == selector }),
                          !scanComponents.contains(where: { Int($0.compIdx) == compIdx }) else {
                        throw JPEGEntropyError.malformed
                    }
                    let comp = layout.components[compIdx]
                    mcuBlocks += comp.horizontalSampling * comp.verticalSampling

                    let qSlot = Int(comp.quantisationTable)
                    guard let qTable = activeQuantTables[qSlot] else {
                        throw JPEGEntropyError.malformed
                    }
                    if layout.marker == 0xC0 && !qTable.allSatisfy({ $0 <= 255 }) {
                        throw JPEGEntropyError.malformed
                    }
                    if let locked = componentQuantTables[compIdx] {
                        guard locked == qTable else {
                            throw JPEGEntropyError.malformed
                        }
                    } else {
                        componentQuantTables[compIdx] = qTable
                    }

                    scanComponents.append(
                        JBRDScanComponent(
                            compIdx: UInt32(compIdx),
                            dcTblIdx: UInt32(dcIdx),
                            acTblIdx: UInt32(acIdx)
                        )
                    )
                }
                if ns > 1 && mcuBlocks > 10 {
                    throw JPEGEntropyError.malformed
                }

                let ss = Int(byte(at: payload.lowerBound + 1 + 2 * ns))
                let se = Int(byte(at: payload.lowerBound + 2 + 2 * ns))
                let approx = byte(at: payload.lowerBound + 3 + 2 * ns)
                let ah = Int(approx >> 4)
                let al = Int(approx & 0x0F)

                let isProgressive = (layout.marker == 0xC2)
                if isProgressive {
                    guard (0...63).contains(ss), (ss...63).contains(se),
                          (0...13).contains(ah), (0...13).contains(al),
                          (ss == 0 ? se == 0 : ns == 1),
                          (ah == 0 || ah == al + 1) else {
                        throw JPEGEntropyError.malformed
                    }
                } else {
                    guard ss == 0, se == 63, ah == 0, al == 0 else {
                        throw JPEGEntropyError.malformed
                    }
                }

                let maxDCAllowed = layout.precision == 12 ? 15 : 11
                let maxACAllowed = layout.precision == 12 ? 14 : 10
                for sc in scanComponents {
                    let ci = Int(sc.compIdx)
                    if ss > 0 && spectralHistory[ci][0] < 0 {
                        throw JPEGEntropyError.malformed
                    }
                    for k in ss...se {
                        let expectedPrev = (ah == 0) ? -1 : ah
                        guard spectralHistory[ci][k] == expectedPrev else {
                            throw JPEGEntropyError.malformed
                        }
                        spectralHistory[ci][k] = al
                    }
                    let needDC = !isProgressive || (ss == 0 && ah == 0)
                    if needDC {
                        let td = Int(sc.dcTblIdx)
                        guard dcTables[td] != nil, dcMaxSymbol[td] <= maxDCAllowed else {
                            throw JPEGEntropyError.malformed
                        }
                    }
                    let needAC = !isProgressive || ss > 0
                    if needAC {
                        let ta = Int(sc.acTblIdx)
                        guard acTables[ta] != nil else {
                            throw JPEGEntropyError.malformed
                        }
                    }
                }

                var entropyReader = try JPEGEntropyReader(
                    data: data,
                    range: segment.entropyRange,
                    checkpoint: { try policy.checkpoint() }
                )
                var dcPredictors = [Int32](repeating: 0, count: layout.components.count)
                var eobRun = 0
                var previousBlockEndedInEOB = false
                var restartIndex = 0
                var resetPoints: [UInt32] = []
                var extraZeroRuns: [JBRDExtraZeroRun] = []

                func recordResetPoint(_ blockIdx: Int) throws {
                    guard totalScanEvents < policy.maximumScanEvents else {
                        throw JPEGEntropyError.resourceLimit
                    }
                    totalScanEvents += 1
                    resetPoints.append(UInt32(blockIdx))
                }

                func recordExtraZeroRun(blockIdx: Int, count: Int) throws {
                    guard (1...4).contains(count) else {
                        throw JPEGEntropyError.malformed
                    }
                    guard totalScanEvents < policy.maximumScanEvents else {
                        throw JPEGEntropyError.resourceLimit
                    }
                    totalScanEvents += 1
                    extraZeroRuns.append(
                        JBRDExtraZeroRun(
                            blockIdx: UInt32(blockIdx),
                            numExtraZeroRuns: UInt32(count)
                        )
                    )
                }

                func decodeBlock(
                    compIdx: Int,
                    dcTblIdx: Int,
                    acTblIdx: Int,
                    storageBlockIndex: Int,
                    scanBlockIndex: Int
                ) throws {
                    if eobRun == 0 || (scanBlockIndex & 63) == 0 {
                        try policy.checkpoint()
                    }
                    let blockBase = storageBlockIndex * 64

                    if !isProgressive {
                        guard let dcTable = dcTables[dcTblIdx],
                              let acTable = acTables[acTblIdx] else {
                            throw JPEGEntropyError.malformed
                        }
                        let dcCat = Int(try dcTable.symbol(&entropyReader))
                        guard dcCat <= maxDCAllowed else { throw JPEGEntropyError.malformed }
                        let dcDiff = try entropyReader.magnitude(dcCat)
                        let (nextDC, dcOverflow) = dcPredictors[compIdx].addingReportingOverflow(dcDiff)
                        guard !dcOverflow else { throw JPEGEntropyError.malformed }
                        dcPredictors[compIdx] = nextDC
                        coefficients[compIdx][blockBase] = nextDC

                        var k = 1
                        var zrlCount = 0
                        while k <= 63 {
                            let rs = Int(try acTable.symbol(&entropyReader))
                            let r = rs >> 4
                            let s = rs & 0x0F
                            if s == 0 {
                                if r == 15 {
                                    guard k + 15 <= 63 else { throw JPEGEntropyError.malformed }
                                    k += 16
                                    zrlCount += 1
                                } else if r == 0 {
                                    break
                                } else {
                                    throw JPEGEntropyError.malformed
                                }
                            } else {
                                guard s <= maxACAllowed else { throw JPEGEntropyError.malformed }
                                k += r
                                guard k <= 63 else { throw JPEGEntropyError.malformed }
                                let acVal = try entropyReader.magnitude(s)
                                coefficients[compIdx][blockBase + JPEGZigZag.order[k]] = acVal
                                zrlCount = 0
                                k += 1
                            }
                        }
                        if zrlCount > 0 {
                            try recordExtraZeroRun(blockIdx: scanBlockIndex, count: zrlCount)
                        }
                        return
                    }

                    if ss == 0 {
                        if ah == 0 {
                            guard let dcTable = dcTables[dcTblIdx] else {
                                throw JPEGEntropyError.malformed
                            }
                            let dcCat = Int(try dcTable.symbol(&entropyReader))
                            guard dcCat <= maxDCAllowed else { throw JPEGEntropyError.malformed }
                            let dcDiff = try entropyReader.magnitude(dcCat)
                            let (nextDC, dcOverflow) = dcPredictors[compIdx].addingReportingOverflow(dcDiff)
                            guard !dcOverflow else { throw JPEGEntropyError.malformed }
                            dcPredictors[compIdx] = nextDC
                            coefficients[compIdx][blockBase] = nextDC << al
                        } else {
                            let bit = try entropyReader.bit()
                            coefficients[compIdx][blockBase] |= Int32(bit << al)
                        }
                        return
                    }

                    guard let acTable = acTables[acTblIdx] else {
                        throw JPEGEntropyError.malformed
                    }

                    if ah == 0 {
                        if eobRun > 0 {
                            eobRun -= 1
                            previousBlockEndedInEOB = true
                            return
                        }
                        var k = ss
                        var zrlCount = 0
                        var endedInEOB = false
                        while k <= se {
                            let rs = Int(try acTable.symbol(&entropyReader))
                            let r = rs >> 4
                            let s = rs & 0x0F
                            if s == 0 {
                                if r == 15 {
                                    guard k + 15 <= se else { throw JPEGEntropyError.malformed }
                                    k += 16
                                    zrlCount += 1
                                } else {
                                    if k == ss && zrlCount == 0 && previousBlockEndedInEOB {
                                        try recordResetPoint(scanBlockIndex)
                                    }
                                    let extra = r == 0 ? 0 : try entropyReader.bits(r)
                                    let run = (1 << r) + extra
                                    eobRun = run - 1
                                    endedInEOB = true
                                    break
                                }
                            } else {
                                guard s <= maxACAllowed else { throw JPEGEntropyError.malformed }
                                k += r
                                guard k <= se else { throw JPEGEntropyError.malformed }
                                let acVal = try entropyReader.magnitude(s)
                                coefficients[compIdx][blockBase + JPEGZigZag.order[k]] = acVal << al
                                zrlCount = 0
                                k += 1
                            }
                        }
                        if zrlCount > 0 {
                            try recordExtraZeroRun(blockIdx: scanBlockIndex, count: zrlCount)
                        }
                        previousBlockEndedInEOB = endedInEOB
                    } else {
                        let plus = Int32(1 << al)
                        let minus = Int32(-1 << al)

                        func refineCoefficient(at index: Int) throws {
                            let current = coefficients[compIdx][index]
                            guard current != 0 else { return }
                            let bit = try entropyReader.bit()
                            if bit != 0 {
                                let delta = current > 0 ? plus : minus
                                let (updated, overflow) = current.addingReportingOverflow(delta)
                                guard !overflow else { throw JPEGEntropyError.malformed }
                                coefficients[compIdx][index] = updated
                            }
                        }

                        if eobRun > 0 {
                            for k in ss...se {
                                try refineCoefficient(at: blockBase + JPEGZigZag.order[k])
                            }
                            eobRun -= 1
                            previousBlockEndedInEOB = true
                            return
                        }

                        var k = ss
                        var zrlCount = 0
                        var endedInEOB = false
                        while k <= se {
                            let rs = Int(try acTable.symbol(&entropyReader))
                            let r = rs >> 4
                            let s = rs & 0x0F
                            if s == 0 {
                                if r == 15 {
                                    var zerosRemaining = 15
                                    while k <= se {
                                        let idx = blockBase + JPEGZigZag.order[k]
                                        if coefficients[compIdx][idx] != 0 {
                                            try refineCoefficient(at: idx)
                                        } else {
                                            if zerosRemaining == 0 { break }
                                            zerosRemaining -= 1
                                        }
                                        k += 1
                                    }
                                    guard k <= se else { throw JPEGEntropyError.malformed }
                                    k += 1
                                    zrlCount += 1
                                } else {
                                    if k == ss && zrlCount == 0 && previousBlockEndedInEOB {
                                        try recordResetPoint(scanBlockIndex)
                                    }
                                    let extra = r == 0 ? 0 : try entropyReader.bits(r)
                                    let run = (1 << r) + extra
                                    while k <= se {
                                        try refineCoefficient(at: blockBase + JPEGZigZag.order[k])
                                        k += 1
                                    }
                                    eobRun = run - 1
                                    endedInEOB = true
                                    break
                                }
                            } else {
                                guard s == 1 else { throw JPEGEntropyError.malformed }
                                let signBit = try entropyReader.bit()
                                let newValue = signBit != 0 ? plus : minus
                                var zerosRemaining = r
                                while k <= se {
                                    let idx = blockBase + JPEGZigZag.order[k]
                                    if coefficients[compIdx][idx] != 0 {
                                        try refineCoefficient(at: idx)
                                    } else {
                                        if zerosRemaining == 0 { break }
                                        zerosRemaining -= 1
                                    }
                                    k += 1
                                }
                                guard k <= se else { throw JPEGEntropyError.malformed }
                                coefficients[compIdx][blockBase + JPEGZigZag.order[k]] = newValue
                                zrlCount = 0
                                k += 1
                            }
                        }
                        if zrlCount > 0 {
                            throw JPEGEntropyError.unsupported
                        }
                        previousBlockEndedInEOB = endedInEOB
                    }
                }

                if ns == 1 {
                    let sc = scanComponents[0]
                    let ci = Int(sc.compIdx)
                    let comp = layout.components[ci]
                    let totalBlocks = comp.singleComponentBlockCount
                    for ordinal in 0..<totalBlocks {
                        if restartInterval > 0 && ordinal > 0 && (ordinal % restartInterval) == 0 {
                            guard eobRun == 0 else { throw JPEGEntropyError.malformed }
                            previousBlockEndedInEOB = false
                            dcPredictors = [Int32](repeating: 0, count: layout.components.count)
                            let pad = try entropyReader.restart(0xD0 + UInt8(restartIndex & 7))
                            restartIndex += 1
                            try appendPadding(pad)
                        }
                        let storageBlock = try comp.storageIndex(forSingleComponentBlock: ordinal)
                        try decodeBlock(
                            compIdx: ci,
                            dcTblIdx: Int(sc.dcTblIdx),
                            acTblIdx: Int(sc.acTblIdx),
                            storageBlockIndex: storageBlock,
                            scanBlockIndex: ordinal
                        )
                    }
                } else {
                    let totalMCUs = layout.mcusWide * layout.mcusHigh
                    var scanBlockIndex = 0
                    for mcu in 0..<totalMCUs {
                        if restartInterval > 0 && mcu > 0 && (mcu % restartInterval) == 0 {
                            guard eobRun == 0 else { throw JPEGEntropyError.malformed }
                            previousBlockEndedInEOB = false
                            dcPredictors = [Int32](repeating: 0, count: layout.components.count)
                            let pad = try entropyReader.restart(0xD0 + UInt8(restartIndex & 7))
                            restartIndex += 1
                            try appendPadding(pad)
                        }
                        let mcuX = mcu % layout.mcusWide
                        let mcuY = mcu / layout.mcusWide
                        for sc in scanComponents {
                            let ci = Int(sc.compIdx)
                            let comp = layout.components[ci]
                            for vy in 0..<comp.verticalSampling {
                                for vx in 0..<comp.horizontalSampling {
                                    let bx = mcuX * comp.horizontalSampling + vx
                                    let by = mcuY * comp.verticalSampling + vy
                                    let storageBlock = by * comp.paddedBlocksWide + bx
                                    try decodeBlock(
                                        compIdx: ci,
                                        dcTblIdx: Int(sc.dcTblIdx),
                                        acTblIdx: Int(sc.acTblIdx),
                                        storageBlockIndex: storageBlock,
                                        scanBlockIndex: scanBlockIndex
                                    )
                                    scanBlockIndex += 1
                                }
                            }
                        }
                    }
                }

                guard eobRun == 0 else {
                    throw JPEGEntropyError.malformed
                }
                let finalPadding = try entropyReader.finish()
                try appendPadding(finalPadding)

                scans.append(
                    JBRDScanInfo(
                        ss: UInt32(ss),
                        se: UInt32(se),
                        ah: UInt32(ah),
                        al: UInt32(al),
                        numComponents: UInt32(ns),
                        components: scanComponents,
                        lastNeededPass: 0,
                        resetPoints: resetPoints,
                        extraZeroRuns: extraZeroRuns
                    )
                )

            case 0xD9:
                sawEOI = true

            default:
                throw JPEGEntropyError.unsupported
            }
        }

        guard sawEOI,
              let layout = frameLayout,
              !scans.isEmpty,
              spectralHistory.allSatisfy({ $0[0] >= 0 }) else {
            throw JPEGEntropyError.malformed
        }

        var resolvedQuant: [[UInt16]] = []
        resolvedQuant.reserveCapacity(layout.components.count)
        for q in componentQuantTables {
            guard let table = q else {
                throw JPEGEntropyError.malformed
            }
            resolvedQuant.append(table)
        }

        try policy.checkpoint()
        return JPEGDecodedCoefficients(
            source: data,
            frame: layout,
            coefficients: coefficients,
            quantisation: resolvedQuant,
            scans: scans,
            padding: paddingRecords
        )
    }
}
