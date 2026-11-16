// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Dispatch
import Foundation
import Synchronization

/// Top-level clean-room VarDCT lossy pixel encoder.
package enum VarDCTPixelEncoder {
    package struct Coefficients: Sendable {
        package let width: Int
        package let height: Int
        package let blocksX: Int
        package let blocksY: Int
        package let bits: Int
        package let grayscale: Bool
        package let hasAlpha: Bool
        package let globalScale: Int
        package let quantAC: [Int32]
        package let strategies: [Int32]
        package let gaborish: Bool
        package let dcSmoothing: Bool
        package let dc: [[Int32]]
        package let ac: [[Int32]]
        package let transforms: [VarDCTStrategyMap.Transform]

        package init(
            width: Int,
            height: Int,
            blocksX: Int,
            blocksY: Int,
            bits: Int,
            grayscale: Bool,
            hasAlpha: Bool,
            globalScale: Int,
            quantAC: [Int32],
            strategies: [Int32],
            gaborish: Bool,
            dcSmoothing: Bool,
            dc: [[Int32]],
            ac: [[Int32]],
            transforms: [VarDCTStrategyMap.Transform]
        ) {
            self.width = width
            self.height = height
            self.blocksX = blocksX
            self.blocksY = blocksY
            self.bits = bits
            self.grayscale = grayscale
            self.hasAlpha = hasAlpha
            self.globalScale = globalScale
            self.quantAC = quantAC
            self.strategies = strategies
            self.gaborish = gaborish
            self.dcSmoothing = dcSmoothing
            self.dc = dc
            self.ac = ac
            self.transforms = transforms
        }
    }

    package static func encode(
        _ bytes: UnsafeRawBufferPointer,
        layouts: [ModularChannelLayout],
        bitsPerSample: Int,
        grayscale: Bool,
        alphaAssociated: Bool?,
        distance: Float,
        gaborish: Bool = false,
        adaptiveQuantisation: Bool = false,
        dcSmoothing: Bool = false,
        smallStrategySearch: Bool = false,
        largeStrategySearch: Bool = false,
        allowExtendedGeometry: Bool = false,
        budget: ScalarOperationBudget
    ) throws -> Data {
        try budget.checkpoint()
        guard distance.isFinite, distance > 0 else {
            throw ScalarModularError.invalidInput("VarDCT distance must be positive and finite")
        }
        guard (8...16).contains(bitsPerSample), alphaAssociated != true else {
            throw ScalarModularError.unsupportedProfile
        }
        let hasAlpha = (alphaAssociated != nil)
        let expectedChannels = (grayscale ? 1 : 3) + (hasAlpha ? 1 : 0)
        guard let first = layouts.first, layouts.count == expectedChannels else {
            throw ScalarModularError.invalidInput("Invalid VarDCT channel layout count")
        }
        let width = first.width
        let height = first.height
        let pixelCount = try ScalarOperationBudget.product(width, height)
        let maxDim = allowExtendedGeometry ? 16384 : 4096
        let maxPixels = allowExtendedGeometry ? (64 * 1024 * 1024) : (4 * 1024 * 1024)
        guard width > 0, height > 0, width <= maxDim, height <= maxDim, pixelCount <= maxPixels else {
            throw ScalarModularError.unsupportedProfile
        }
        for layout in layouts {
            guard layout.width == width,
                  layout.height == height,
                  (8...16).contains(layout.storageBits),
                  bitsPerSample <= layout.storageBits else {
                throw ScalarModularError.invalidInput("Inconsistent VarDCT channel layout")
            }
            guard bytes.count >= layout.requiredBytes else {
                throw ScalarModularError.invalidInput("Source buffer shorter than layout requirement")
            }
        }

        let blocksX = (width + 7) / 8
        let blocksY = (height + 7) / 8
        let totalBlocks = try ScalarOperationBudget.product(blocksX, blocksY)
        let baseAdmission = 4 * 1024 * 1024
        let planeAdmission = try ScalarOperationBudget.product(pixelCount, 3 * MemoryLayout<Float>.stride)
        let blockAdmission = try ScalarOperationBudget.product(totalBlocks, 64 * 3 * MemoryLayout<Int32>.stride)
        try budget.reserveWorkspace(
            ScalarOperationBudget.sum(baseAdmission, ScalarOperationBudget.sum(planeAdmission, blockAdmission))
        )

        let maximum = (Int32(1) << bitsPerSample) - 1
        let source = VarDCTBorrowedSource(bytes: bytes, layouts: layouts, maximum: maximum)
        let lutCount = 1 << bitsPerSample
        let lutBytes = lutCount * (MemoryLayout<Double>.stride + (grayscale ? MemoryLayout<(Float, Float, Float)>.stride : 0))
        let useTable = bitsPerSample == 8 || (
            pixelCount >= 4096 &&
            budget.maximumWorkspaceBytes - budget.reservedWorkspaceBytes >= lutBytes + 4 * 1024 * 1024
        )
        let sampleTable = try useTable
            ? VarDCTEncoderPreparation.SampleConversion(bitsPerSample: bitsPerSample, grayscale: grayscale, budget: budget)
            : nil

        var planes = [
            [Float](repeating: 0, count: pixelCount),
            [Float](repeating: 0, count: pixelCount),
            [Float](repeating: 0, count: pixelCount)
        ]

        let invMax = 1.0 / Double(maximum)
        @inline(__always)
        @Sendable func srgbToLinear(_ s: Int32) -> Double {
            let v = Double(s) * invMax
            return v <= 0.04045 ? (v / 12.92) : pow((v + 0.055) / 1.055, 2.4)
        }

        let convWorkers = min(max(1, budget.maximumWorkers), height >= 32 ? min(8, height) : 1)
        let rawSourceAddr = Int(bitPattern: bytes.baseAddress!)
        let rawSourceCount = bytes.count
        var plane0 = planes[0]
        var plane1 = planes[1]
        var plane2 = planes[2]
        planes = []
        try plane0.withUnsafeMutableBufferPointer { p0Buf in
            try plane1.withUnsafeMutableBufferPointer { p1Buf in
                try plane2.withUnsafeMutableBufferPointer { p2Buf in
                    let p0Addr = Int(bitPattern: p0Buf.baseAddress!)
                    let p1Addr = Int(bitPattern: p1Buf.baseAddress!)
                    let p2Addr = Int(bitPattern: p2Buf.baseAddress!)

                    @Sendable
                    func convertRows(_ yStart: Int, _ yEnd: Int) throws {
                        let localBytes = UnsafeRawBufferPointer(
                            start: UnsafeRawPointer(bitPattern: rawSourceAddr),
                            count: rawSourceCount
                        )
                        let localSource = VarDCTBorrowedSource(bytes: localBytes, layouts: layouts, maximum: maximum)
                        let p0 = UnsafeMutablePointer<Float>(bitPattern: p0Addr)!
                        let p1 = UnsafeMutablePointer<Float>(bitPattern: p1Addr)!
                        let p2 = UnsafeMutablePointer<Float>(bitPattern: p2Addr)!

                        for y in yStart..<yEnd {
                            if (y & 15) == 0 { try budget.checkpoint() }
                            let rowOffset = y * width
                            if grayscale {
                                if let table = sampleTable {
                                    try table.grayscale.withUnsafeBufferPointer { tblBuf in
                                        let tbl = tblBuf.baseAddress!
                                        for x in 0..<width {
                                            let sample = try localSource.sample(channel: 0, x: x, y: y)
                                            let idx = rowOffset + x
                                            let xyb = tbl[Int(sample)]
                                            p0[idx] = xyb.0
                                            p1[idx] = xyb.1
                                            p2[idx] = xyb.2
                                        }
                                    }
                                } else {
                                    for x in 0..<width {
                                        let sample = try localSource.sample(channel: 0, x: x, y: y)
                                        let idx = rowOffset + x
                                        let lin = srgbToLinear(sample)
                                        let xyb = try DefaultOpsin.forward((lin, lin, lin))
                                        p0[idx] = Float(xyb.X)
                                        p1[idx] = Float(xyb.Y)
                                        p2[idx] = Float(xyb.B)
                                    }
                                }
                            } else {
                                if let table = sampleTable {
                                    try table.linear.withUnsafeBufferPointer { linBuf in
                                        let lin = linBuf.baseAddress!
                                        for x in 0..<width {
                                            let sr = try localSource.sample(channel: 0, x: x, y: y)
                                            let sg = try localSource.sample(channel: 1, x: x, y: y)
                                            let sb = try localSource.sample(channel: 2, x: x, y: y)
                                            let xyb = try DefaultOpsin.forward((lin[Int(sr)], lin[Int(sg)], lin[Int(sb)]))
                                            let idx = rowOffset + x
                                            p0[idx] = Float(xyb.X)
                                            p1[idx] = Float(xyb.Y)
                                            p2[idx] = Float(xyb.B)
                                        }
                                    }
                                } else {
                                    for x in 0..<width {
                                        let sr = try localSource.sample(channel: 0, x: x, y: y)
                                        let sg = try localSource.sample(channel: 1, x: x, y: y)
                                        let sb = try localSource.sample(channel: 2, x: x, y: y)
                                        let xyb = try DefaultOpsin.forward((srgbToLinear(sr), srgbToLinear(sg), srgbToLinear(sb)))
                                        let idx = rowOffset + x
                                        p0[idx] = Float(xyb.X)
                                        p1[idx] = Float(xyb.Y)
                                        p2[idx] = Float(xyb.B)
                                    }
                                }
                            }
                        }
                    }

                    if convWorkers <= 1 {
                        try convertRows(0, height)
                    } else {
                        let errMutex = PackageMutex<(any Error)?>(nil)
                        let rowsPerWorker = (height + convWorkers - 1) / convWorkers
                        DispatchQueue.concurrentPerform(iterations: convWorkers) { w in
                            let y0 = w * rowsPerWorker
                            let y1 = min(height, y0 + rowsPerWorker)
                            guard y0 < y1 else { return }
                            do {
                                try convertRows(y0, y1)
                            } catch {
                                errMutex.withLock { if $0 == nil { $0 = error } }
                            }
                        }
                        if let err = errMutex.withLock({ $0 }) { throw err }
                    }
                }
            }
        }
        planes = [plane0, plane1, plane2]

        if gaborish {
            for c in 0..<3 {
                planes[c] = try VarDCTEncoderPreparation.inverseGaborish(
                    planes[c],
                    width: width,
                    height: height,
                    budget: budget
                )
            }
        }

        let globalScale = max(1, min(65535, Int((5111.0 / Double(distance)).rounded())))
        let writerLimit = budget.maximumCompressedBytes

        if largeStrategySearch {
            let result = try VarDCTHierarchicalAnalysis.analyse(
                planes,
                width: width,
                height: height,
                scale: globalScale,
                distance: distance,
                adaptiveQuantisation: adaptiveQuantisation,
                budget: budget
            )
            let coefficients = Coefficients(
                width: width,
                height: height,
                blocksX: blocksX,
                blocksY: blocksY,
                bits: bitsPerSample,
                grayscale: grayscale,
                hasAlpha: hasAlpha,
                globalScale: globalScale,
                quantAC: result.quantisation,
                strategies: result.strategies,
                gaborish: gaborish,
                dcSmoothing: dcSmoothing,
                dc: result.dc,
                ac: result.ac,
                transforms: result.transforms
            )
            return try ScalarEncodingWork.$current.withValue(.init(budget: budget, writerByteLimit: writerLimit)) {
                try VarDCTFrameWriter(
                    coefficients: coefficients,
                    source: source,
                    budget: budget,
                    limit: writerLimit
                ).write()
            }
        }

        // Single-cell (8x8) analysis path — zero per-block heap allocations + multi-worker block-row parallelism
        let smallPlan = try VarDCTSmallAnalysis(budget: budget)
        let candidateIDs = smallStrategySearch ? VarDCTSmallAnalysis.supportedIdentifiers : [0]
        var weightTables = [[Float]?](repeating: nil, count: 18)
        for id in candidateIDs {
            weightTables[id] = try VarDCTQuantWeights.make(identifier: id, rows: 8, columns: 8, budget: budget)
        }
        let naturalOrder = VarDCTFrameWriter.order
        let dcScale0 = Double(globalScale) * 17.0 * 4096.0 / 65536.0
        let dcScale1 = Double(globalScale) * 17.0 * 512.0 / 65536.0
        let dcScale2 = Double(globalScale) * 17.0 * 256.0 / 65536.0
        let acScaleBase = Double(globalScale) / 65536.0

        let cellWorkers = (budget.maximumWorkers > 1 && blocksY >= 4 &&
            budget.maximumWorkspaceBytes - budget.reservedWorkspaceBytes >= 512 * 1024)
            ? min(8, min(budget.maximumWorkers, blocksY))
            : 1

        struct SingleCellScratch {
            var small: VarDCTSmallAnalysis.Workspace
            var patch: [Float]
            var cflPatch: [Float]
            var candAC: [Int32]
            var bestAC: [Int32]
            init(budget: ScalarOperationBudget) throws {
                self.small = try VarDCTSmallAnalysis.Workspace(budget: budget)
                try budget.reserveWorkspace(384 * MemoryLayout<Float>.stride + 384 * MemoryLayout<Int32>.stride)
                self.patch = [Float](repeating: 0, count: 192)
                self.cflPatch = [Float](repeating: 0, count: 192)
                self.candAC = [Int32](repeating: 0, count: 192)
                self.bestAC = [Int32](repeating: 0, count: 192)
            }
        }

        var cellScratches: [SingleCellScratch] = []
        cellScratches.reserveCapacity(cellWorkers)
        for _ in 0..<cellWorkers {
            cellScratches.append(try SingleCellScratch(budget: budget))
        }

        var strategies = [Int32](repeating: 0, count: totalBlocks)
        var quantAC = [Int32](repeating: 5, count: totalBlocks)
        var dc0 = [Int32](repeating: 0, count: totalBlocks)
        var dc1 = [Int32](repeating: 0, count: totalBlocks)
        var dc2 = [Int32](repeating: 0, count: totalBlocks)
        var ac0 = [Int32](repeating: 0, count: totalBlocks * 64)
        var ac1 = [Int32](repeating: 0, count: totalBlocks * 64)
        var ac2 = [Int32](repeating: 0, count: totalBlocks * 64)

        let immutableWeights = weightTables
        let immutablePlanes = planes

        try immutablePlanes[0].withUnsafeBufferPointer { p0Buf in
            try immutablePlanes[1].withUnsafeBufferPointer { p1Buf in
                try immutablePlanes[2].withUnsafeBufferPointer { p2Buf in
                    try strategies.withUnsafeMutableBufferPointer { stratBuf in
                        try quantAC.withUnsafeMutableBufferPointer { qfBuf in
                            try dc0.withUnsafeMutableBufferPointer { d0Buf in
                                try dc1.withUnsafeMutableBufferPointer { d1Buf in
                                    try dc2.withUnsafeMutableBufferPointer { d2Buf in
                                        try ac0.withUnsafeMutableBufferPointer { a0Buf in
                                            try ac1.withUnsafeMutableBufferPointer { a1Buf in
                                                try ac2.withUnsafeMutableBufferPointer { a2Buf in
                                                    let p0Addr = Int(bitPattern: p0Buf.baseAddress!)
                                                    let p1Addr = Int(bitPattern: p1Buf.baseAddress!)
                                                    let p2Addr = Int(bitPattern: p2Buf.baseAddress!)
                                                    let stratAddr = Int(bitPattern: stratBuf.baseAddress!)
                                                    let qfAddr = Int(bitPattern: qfBuf.baseAddress!)
                                                    let d0Addr = Int(bitPattern: d0Buf.baseAddress!)
                                                    let d1Addr = Int(bitPattern: d1Buf.baseAddress!)
                                                    let d2Addr = Int(bitPattern: d2Buf.baseAddress!)
                                                    let a0Addr = Int(bitPattern: a0Buf.baseAddress!)
                                                    let a1Addr = Int(bitPattern: a1Buf.baseAddress!)
                                                    let a2Addr = Int(bitPattern: a2Buf.baseAddress!)

                                                    @Sendable
                                                    func processBlockRow(_ by: Int, scratch: inout SingleCellScratch) throws {
                                                        try budget.checkpoint()
                                                        let p0 = UnsafePointer<Float>(bitPattern: p0Addr)!
                                                        let p1 = UnsafePointer<Float>(bitPattern: p1Addr)!
                                                        let p2 = UnsafePointer<Float>(bitPattern: p2Addr)!
                                                        let stratOut = UnsafeMutablePointer<Int32>(bitPattern: stratAddr)!
                                                        let qfOut = UnsafeMutablePointer<Int32>(bitPattern: qfAddr)!
                                                        let d0Out = UnsafeMutablePointer<Int32>(bitPattern: d0Addr)!
                                                        let d1Out = UnsafeMutablePointer<Int32>(bitPattern: d1Addr)!
                                                        let d2Out = UnsafeMutablePointer<Int32>(bitPattern: d2Addr)!
                                                        let a0Out = UnsafeMutablePointer<Int32>(bitPattern: a0Addr)!
                                                        let a1Out = UnsafeMutablePointer<Int32>(bitPattern: a1Addr)!
                                                        let a2Out = UnsafeMutablePointer<Int32>(bitPattern: a2Addr)!

                                                        try naturalOrder.withUnsafeBufferPointer { natOrdBuf in
                                                                let natOrd = natOrdBuf.baseAddress!

                                                                for bx in 0..<blocksX {
                                                                    let block = by &* blocksX &+ bx
                                                                    try scratch.patch.withUnsafeMutableBufferPointer { patchBuf in
                                                                        let patchPtr = patchBuf.baseAddress!
                                                                        let baseX = bx &* 8
                                                                        for y in 0..<8 {
                                                                            let sy = min(height - 1, by &* 8 &+ y) &* width
                                                                            let rOff = y &* 8
                                                                            if baseX + 8 <= width {
                                                                                let sBase = sy &+ baseX
                                                                                for x in 0..<8 {
                                                                                    let v0 = p0[sBase &+ x]
                                                                                    let v1 = p1[sBase &+ x]
                                                                                    let v2 = p2[sBase &+ x]
                                                                                    guard v0.isFinite, v1.isFinite, v2.isFinite else {
                                                                                        throw VarDCTError.nonFiniteSample
                                                                                    }
                                                                                    patchPtr[rOff &+ x] = v0
                                                                                    patchPtr[64 &+ rOff &+ x] = v1
                                                                                    patchPtr[128 &+ rOff &+ x] = v2
                                                                                }
                                                                            } else {
                                                                                for x in 0..<8 {
                                                                                    let idx = sy &+ min(width - 1, baseX &+ x)
                                                                                    let v0 = p0[idx]
                                                                                    let v1 = p1[idx]
                                                                                    let v2 = p2[idx]
                                                                                    guard v0.isFinite, v1.isFinite, v2.isFinite else {
                                                                                        throw VarDCTError.nonFiniteSample
                                                                                    }
                                                                                    patchPtr[rOff &+ x] = v0
                                                                                    patchPtr[64 &+ rOff &+ x] = v1
                                                                                    patchPtr[128 &+ rOff &+ x] = v2
                                                                                }
                                                                            }
                                                                        }
                                                                    }

                                                                    scratch.patch.withUnsafeBufferPointer { patchBuf in
                                                                        scratch.cflPatch.withUnsafeMutableBufferPointer { cflBuf in
                                                                            let src = patchBuf.baseAddress!
                                                                            let dst = cflBuf.baseAddress!
                                                                            dst.update(from: src, count: 128)
                                                                            for i in 0..<64 {
                                                                                dst[128 &+ i] = src[128 &+ i] - src[64 &+ i]
                                                                            }
                                                                        }
                                                                    }

                                                                    let qf: Int32 = adaptiveQuantisation
                                                                        ? try scratch.patch.withUnsafeBufferPointer {
                                                                            try VarDCTEncoderPreparation.quantisation($0, distance: distance)
                                                                        }
                                                                        : 5
                                                                    qfOut[block] = qf
                                                                    let qScale = acScaleBase * Double(qf)

                                                                    if candidateIDs.count == 1 && candidateIDs[0] == 0 {
                                                                        let acOffset = block &* 64
                                                                        immutableWeights[0]!.withUnsafeBufferPointer { wBuf in
                                                                            let weights = wBuf.baseAddress!
                                                                            for c in 0..<3 {
                                                                                scratch.cflPatch.withUnsafeBufferPointer { cflBuf in
                                                                                    smallPlan.applyFast(cflBuf.baseAddress! + (c &* 64), identifier: 0, workspace: &scratch.small)
                                                                                }
                                                                                scratch.small.withOutputBuffer { outBuf in
                                                                                    let coeffs = outBuf.baseAddress!
                                                                                    let dScale = (c == 0) ? dcScale0 : (c == 1 ? dcScale1 : dcScale2)
                                                                                    let dcVal = Int32((Double(coeffs[0]) * dScale).rounded())
                                                                                    let aOut: UnsafeMutablePointer<Int32>
                                                                                    if c == 0 {
                                                                                        d0Out[block] = dcVal; aOut = a0Out
                                                                                    } else if c == 1 {
                                                                                        d1Out[block] = dcVal; aOut = a1Out
                                                                                    } else {
                                                                                        d2Out[block] = dcVal; aOut = a2Out
                                                                                    }
                                                                                    let wBase = c &* 64
                                                                                    aOut[acOffset] = 0
                                                                                    for k in 1..<64 {
                                                                                        let pos = natOrd[k]
                                                                                        aOut[acOffset &+ pos] = Int32((Double(coeffs[pos]) * Double(weights[wBase &+ pos]) * qScale).rounded())
                                                                                    }
                                                                                }
                                                                            }
                                                                        }
                                                                        stratOut[block] = 0
                                                                    } else {
                                                                        var bestID = 0
                                                                        var bestCost = Double.infinity
                                                                        var bestDC = (Int32(0), Int32(0), Int32(0))

                                                                        for id in candidateIDs {
                                                                            var candDC = (Int32(0), Int32(0), Int32(0))
                                                                            var nonZeros = 0
                                                                            var acEnergy = 0.0

                                                                            immutableWeights[id]!.withUnsafeBufferPointer { wBuf in
                                                                                let weights = wBuf.baseAddress!
                                                                                scratch.candAC.withUnsafeMutableBufferPointer { candBuf in
                                                                                    let candPtr = candBuf.baseAddress!
                                                                                    for c in 0..<3 {
                                                                                        scratch.cflPatch.withUnsafeBufferPointer { cflBuf in
                                                                                            smallPlan.applyFast(cflBuf.baseAddress! + (c &* 64), identifier: id, workspace: &scratch.small)
                                                                                        }
                                                                                        scratch.small.withOutputBuffer { outBuf in
                                                                                            let coeffs = outBuf.baseAddress!
                                                                                            let dScale = (c == 0) ? dcScale0 : (c == 1 ? dcScale1 : dcScale2)
                                                                                            let dcVal = Int32((Double(coeffs[0]) * dScale).rounded())
                                                                                            if c == 0 { candDC.0 = dcVal }
                                                                                            else if c == 1 { candDC.1 = dcVal }
                                                                                            else { candDC.2 = dcVal }
                                                                                            let wBase = c &* 64
                                                                                            candPtr[wBase] = 0
                                                                                            for k in 1..<64 {
                                                                                                let pos = natOrd[k]
                                                                                                let q = Int32((Double(coeffs[pos]) * Double(weights[wBase &+ pos]) * qScale).rounded())
                                                                                                candPtr[wBase &+ pos] = q
                                                                                                if q != 0 {
                                                                                                    nonZeros &+= 1
                                                                                                    acEnergy += abs(Double(q))
                                                                                                }
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                }
                                                                            }

                                                                            let penalty = (id == 0) ? 0.0 : 1.5
                                                                            let cost = Double(nonZeros) * 3.5 + acEnergy * 0.25 + penalty
                                                                            if cost + (id == 0 ? 0.0 : 0.5) < bestCost {
                                                                                bestCost = cost
                                                                                bestID = id
                                                                                bestDC = candDC
                                                                                swap(&scratch.bestAC, &scratch.candAC)
                                                                            }
                                                                        }

                                                                        stratOut[block] = Int32(bestID)
                                                                        d0Out[block] = bestDC.0
                                                                        d1Out[block] = bestDC.1
                                                                        d2Out[block] = bestDC.2
                                                                        let acOffset = block &* 64
                                                                        scratch.bestAC.withUnsafeBufferPointer { bestBuf in
                                                                            let bPtr = bestBuf.baseAddress!
                                                                            a0Out.advanced(by: acOffset).update(from: bPtr, count: 64)
                                                                            a1Out.advanced(by: acOffset).update(from: bPtr.advanced(by: 64), count: 64)
                                                                            a2Out.advanced(by: acOffset).update(from: bPtr.advanced(by: 128), count: 64)
                                                                        }
                                                                    }
                                                                }
                                                        }
                                                    }

                                                    if cellWorkers <= 1 {
                                                        for by in 0..<blocksY {
                                                            try processBlockRow(by, scratch: &cellScratches[0])
                                                        }
                                                    } else {
                                                        let audit = ScalarStorageAudit.current
                                                        let nextRow = Atomic<Int>(0)
                                                        let errMutex = PackageMutex<(any Error)?>(nil)
                                                        cellScratches.withUnsafeMutableBufferPointer { scBuf in
                                                            let scAddr = Int(bitPattern: scBuf.baseAddress!)
                                                            DispatchQueue.concurrentPerform(iterations: cellWorkers) { w in
                                                                audit?.workerStarted()
                                                                defer { audit?.workerCompleted() }
                                                                let sPtr = UnsafeMutablePointer<SingleCellScratch>(bitPattern: scAddr)! + w
                                                                while true {
                                                                    if errMutex.withLock({ $0 != nil }) { break }
                                                                    let by = nextRow.wrappingAdd(1, ordering: .relaxed).oldValue
                                                                    if by >= blocksY { break }
                                                                    do {
                                                                        try processBlockRow(by, scratch: &sPtr.pointee)
                                                                    } catch {
                                                                        errMutex.withLock { if $0 == nil { $0 = error } }
                                                                        break
                                                                    }
                                                                }
                                                            }
                                                        }
                                                        if let err = errMutex.withLock({ $0 }) { throw err }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        var transforms: [VarDCTStrategyMap.Transform] = []
        transforms.reserveCapacity(totalBlocks)
        for by in 0..<blocksY {
            let rowBase = by * blocksX
            for bx in 0..<blocksX {
                let block = rowBase + bx
                transforms.append(
                    VarDCTStrategyMap.Transform(
                        identifier: Int(strategies[block]),
                        x: bx,
                        y: by,
                        cellsX: 1,
                        cellsY: 1,
                        quantisation: UInt32(quantAC[block]),
                        coefficientOffset: block * 64
                    )
                )
            }
        }
        let dc = [dc0, dc1, dc2]
        let ac = [ac0, ac1, ac2]

        let coefficients = Coefficients(
            width: width,
            height: height,
            blocksX: blocksX,
            blocksY: blocksY,
            bits: bitsPerSample,
            grayscale: grayscale,
            hasAlpha: hasAlpha,
            globalScale: globalScale,
            quantAC: quantAC,
            strategies: strategies,
            gaborish: gaborish,
            dcSmoothing: dcSmoothing,
            dc: dc,
            ac: ac,
            transforms: transforms
        )
        return try ScalarEncodingWork.$current.withValue(.init(budget: budget, writerByteLimit: writerLimit)) {
            try VarDCTFrameWriter(
                coefficients: coefficients,
                source: source,
                budget: budget,
                limit: writerLimit
            ).write()
        }
    }
}

/// Borrowed pixel buffer accessor that validates sample precision without copying source planes.
struct VarDCTBorrowedSource {
    let bytes: UnsafeRawBufferPointer
    let layouts: [ModularChannelLayout]
    let maximum: Int32

    @inline(__always)
    func sample(channel: Int, x: Int, y: Int) throws -> Int32 {
        let layout = layouts[channel]
        let offset = layout.offset + y * layout.rowBytes + x * layout.pixelStride
        let raw: Int32
        if layout.storageBits == 8 {
            raw = Int32(bytes[offset])
        } else if layout.littleEndian {
            raw = Int32(bytes[offset]) | (Int32(bytes[offset + 1]) << 8)
        } else {
            raw = (Int32(bytes[offset]) << 8) | Int32(bytes[offset + 1])
        }
        guard raw >= 0, raw <= maximum else {
            throw ScalarModularError.invalidInput("Source sample exceeds meaningful precision")
        }
        return raw
    }
}
