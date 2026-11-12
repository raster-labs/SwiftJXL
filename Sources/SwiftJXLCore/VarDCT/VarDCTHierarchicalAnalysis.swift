// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Dispatch
import Foundation
import Synchronization

/// Clean-room hierarchical VarDCT transform strategy (`AcStrategy`) and coefficient analysis.
package enum VarDCTHierarchicalAnalysis {
    package struct Result: Sendable {
        package let strategies: [Int32]
        package let quantisation: [Int32]
        package let dc: [[Int32]]
        package let ac: [[Int32]]
        package let transforms: [VarDCTStrategyMap.Transform]
    }

    private struct WorkerScratch {
        var small: VarDCTSmallAnalysis.Workspace
        var large: VarDCTLargeAnalysis.Workspace
        var patch3x64: [Float]
        var patchLarge: [Float]
        var tilePlanes: [Float]
        var candDC: [Int32]
        var candAC: [Int32]
        var bestDC1x1: [Int32]
        var bestAC1x1: [Int32]
        var cached4x4: [Float]
        var cached4x8: [Float]
        var cellPatch3x64: [Float]

        init(budget: ScalarOperationBudget) throws {
            self.small = try VarDCTSmallAnalysis.Workspace(budget: budget)
            self.large = try VarDCTLargeAnalysis.Workspace(capacity: 4096, budget: budget)
            try budget.reserveWorkspace((192 + 4096) * MemoryLayout<Float>.stride)
            self.patch3x64 = [Float](repeating: 0, count: 192)
            self.patchLarge = [Float](repeating: 0, count: 4096)
            self.tilePlanes = [Float](repeating: 0, count: 3 * 4096)
            self.candDC = [Int32](repeating: 0, count: 3 * 64)
            self.candAC = [Int32](repeating: 0, count: 3 * 4096)
            self.bestDC1x1 = [Int32](repeating: 0, count: 3)
            self.bestAC1x1 = [Int32](repeating: 0, count: 3 * 64)
            self.cached4x4 = [Float](repeating: 0, count: 3 * 64)
            self.cached4x8 = [Float](repeating: 0, count: 3 * 64)
            self.cellPatch3x64 = [Float](repeating: 0, count: 3 * 64)
        }
    }

    private struct SelectedLeaf: Sendable {
        let identifier: Int
        let x: Int
        let y: Int
        let cellsX: Int
        let cellsY: Int
        let quantisation: Int32
        let dc: [[Int32]]
        let ac: [[Int32]]
        let cost: Double
    }

    private struct TileAnalysisResult: Sendable {
        let leaves: [SelectedLeaf]
    }

    package static func analyse(
        _ planes: [[Float]],
        width: Int,
        height: Int,
        scale: Int,
        distance: Float,
        adaptiveQuantisation: Bool,
        budget: ScalarOperationBudget
    ) throws -> Result {
        try budget.checkpoint()
        guard width > 0, height > 0, scale > 0, distance.isFinite, distance > 0, planes.count == 3 else {
            throw VarDCTError.invalidTransform
        }
        let pixelCount = try ScalarOperationBudget.product(width, height)
        guard planes.allSatisfy({ $0.count == pixelCount }) else {
            throw VarDCTError.invalidTransform
        }

        let bx = (width + 7) / 8
        let by = (height + 7) / 8
        let totalBlocks = try ScalarOperationBudget.product(bx, by)
        let totalCoefficients = try ScalarOperationBudget.product(totalBlocks, 64)
        let tilesX = (bx + 7) / 8
        let tilesY = (by + 7) / 8
        let totalTiles = try ScalarOperationBudget.product(tilesX, tilesY)

        // Reserve output buffers and precompute transform plans, quant weights, and natural scan orders
        try budget.reserveWorkspace(
            ScalarOperationBudget.product(totalBlocks * 5 + totalCoefficients * 3, MemoryLayout<Int32>.stride)
        )

        var axes = ScaledDCT.AxisBank(direction: .forward, budget: budget)
        let smallPlan = try VarDCTSmallAnalysis(budget: budget, axes: &axes)
        var largePlans = [VarDCTLargeAnalysis?](repeating: nil, count: 21)
        for id in [4, 5, 6, 7, 8, 9, 10, 11, 18, 19, 20] {
            largePlans[id] = try VarDCTLargeAnalysis(identifier: id, budget: budget, axes: &axes)
        }

        var weightTables = [[Float]?](repeating: nil, count: 21)
        var orderTables = [[Int]?](repeating: nil, count: 21)
        for id in 0...20 {
            let rows: Int
            let cols: Int
            if let shape = VarDCTLargeAnalysis.dimensions(for: id) {
                rows = shape.rows
                cols = shape.columns
            } else {
                rows = 8
                cols = 8
            }
            weightTables[id] = try VarDCTQuantWeights.make(
                identifier: id,
                rows: rows,
                columns: columns(for: id),
                budget: budget
            )
            let maxCells = max(rows, cols) / 8
            let minCells = min(rows, cols) / 8
            orderTables[id] = (id >= 14 && id <= 17)
                ? try VarDCTOrders.naturalAFV(budget: budget)
                : try VarDCTOrders.natural(width: maxCells, height: minCells, budget: budget)
        }

        let workerCap = min(3, max(1, budget.maximumWorkers))
        let scratchCount = totalTiles > 1 ? min(workerCap, totalTiles) : 1
        var scratches: [WorkerScratch] = []
        scratches.reserveCapacity(scratchCount)
        for _ in 0..<scratchCount {
            scratches.append(try WorkerScratch(budget: budget))
        }

        let dcScales = [4096.0, 512.0, 256.0].map { Double(scale) * 17.0 * $0 / 65536.0 }
        let acScaleBase = Double(scale) / 65536.0
        var tileResults = [TileAnalysisResult?](repeating: nil, count: totalTiles)
        let ImmutablePlanes = planes
        let immutableLargePlans = largePlans
        let immutableWeights = weightTables

        @Sendable
        func processTile(_ tileIndex: Int, scratch: inout WorkerScratch) throws -> TileAnalysisResult {
            try budget.checkpoint()
            let tx = tileIndex % tilesX
            let ty = tileIndex / tilesX
            let cellX0 = tx * 8
            let cellY0 = ty * 8
            let tileCellsX = min(8, bx - cellX0)
            let tileCellsY = min(8, by - cellY0)

            // Validate finiteness of all samples in this tile up front
            let pyStart = cellY0 * 8
            let pyEnd = min(height, (cellY0 + tileCellsY) * 8)
            let pxStart = cellX0 * 8
            let pxEnd = min(width, (cellX0 + tileCellsX) * 8)
            for c in 0..<3 {
                let plane = ImmutablePlanes[c]
                for py in pyStart..<pyEnd {
                    let row = py * width
                    for px in pxStart..<pxEnd {
                        guard plane[row + px].isFinite else {
                            throw VarDCTError.nonFiniteSample
                        }
                    }
                }
            }

            // Pre-extract the 64x64 tile (with B - Y in channel 2 and edge clamping) once per tile
            let tileRows = tileCellsY * 8
            let tileCols = tileCellsX * 8
            ImmutablePlanes[0].withUnsafeBufferPointer { p0Buf in
                ImmutablePlanes[1].withUnsafeBufferPointer { p1Buf in
                    ImmutablePlanes[2].withUnsafeBufferPointer { p2Buf in
                        scratch.tilePlanes.withUnsafeMutableBufferPointer { tileBuf in
                            let p0 = p0Buf.baseAddress!
                            let p1 = p1Buf.baseAddress!
                            let p2 = p2Buf.baseAddress!
                            let t0 = tileBuf.baseAddress!
                            let t1 = t0 + 4096
                            let t2 = t0 + 8192
                            for y in 0..<tileRows {
                                let sy = min(height - 1, pyStart + y) * width
                                let dstRow = y * 64
                                for x in 0..<tileCols {
                                    let sx = min(width - 1, pxStart + x)
                                    let idx = sy + sx
                                    let yVal = p1[idx]
                                    t0[dstRow + x] = p0[idx]
                                    t1[dstRow + x] = yVal
                                    t2[dstRow + x] = p2[idx] - yVal
                                }
                            }
                        }
                    }
                }
            }

            // Compute region quantisation from top-left 8x8 cell of the tile
            let regionQF: Int32
            if adaptiveQuantisation {
                for c in 0..<3 {
                    let plane = ImmutablePlanes[c]
                    let base = c * 64
                    for y in 0..<8 {
                        let sy = min(height - 1, cellY0 * 8 + y) * width
                        for x in 0..<8 {
                            let sx = min(width - 1, cellX0 * 8 + x)
                            scratch.patch3x64[base + y * 8 + x] = plane[sy + sx]
                        }
                    }
                }
                regionQF = try scratch.patch3x64.withUnsafeBufferPointer { buf in
                    try VarDCTEncoderPreparation.quantisation(buf, distance: distance)
                }
            } else {
                regionQF = 5
            }

            let qScale = acScaleBase * Double(regionQF)

            func evaluateLargeTransform(
                id: Int,
                cx: Int,
                cy: Int,
                cellsW: Int,
                cellsH: Int,
                maxCost: Double = .infinity,
                allowTie: Bool = false
            ) -> (leaf: SelectedLeaf?, cost: Double) {
                let rows = cellsH * 8
                let cols = cellsW * 8
                let count = rows * cols
                let covered = cellsW * cellsH
                let normCols = max(rows, cols)
                let llfRows = min(cellsW, cellsH)
                let llfCols = max(cellsW, cellsH)
                let weights = immutableWeights[id]!
                let plan = immutableLargePlans[id]!
                let localX0 = (cx - cellX0) * 8
                let localY0 = (cy - cellY0) * 8

                let transformOverhead = 1.0
                let sizePenalty = (id == 0 || id == 4 || id == 5 || id == 18) ? 0.0 : 0.5
                let fixedBaseCost = transformOverhead + sizePenalty
                let spanWeight = Double(cellsW + cellsH)

                var acEnergy = 0.0
                var nonZeroCount = 0
                var dcHet = 0.0
                var pruned = false
                var prunedCost = Double.infinity

                scratch.tilePlanes.withUnsafeBufferPointer { tileBuf in
                    scratch.patchLarge.withUnsafeMutableBufferPointer { patchBuf in
                        scratch.candDC.withUnsafeMutableBufferPointer { dcBuf in
                            scratch.candAC.withUnsafeMutableBufferPointer { acBuf in
                                weights.withUnsafeBufferPointer { wBuf in
                                    let tileBase = tileBuf.baseAddress!
                                    let patchPtr = patchBuf.baseAddress!
                                    let dcPtr = dcBuf.baseAddress!
                                    let acPtr = acBuf.baseAddress!
                                    let wPtr = wBuf.baseAddress!

                                    let channelOrder = (1, 0, 2)
                                    for step in 0..<3 {
                                        let c = step == 0 ? channelOrder.0 : (step == 1 ? channelOrder.1 : channelOrder.2)
                                        let srcChannel = tileBase + c * 4096 + localY0 * 64 + localX0
                                        if cols == 64 {
                                            plan.applyDCTAndDCUnchecked(srcChannel, workspace: &scratch.large)
                                        } else {
                                            for y in 0..<rows {
                                                (patchPtr + y * cols).update(from: srcChannel + y * 64, count: cols)
                                            }
                                            plan.applyDCTAndDCUnchecked(patchPtr, workspace: &scratch.large)
                                        }

                                        let dcScaleC = dcScales[c]
                                        let cDC = dcPtr + c * covered
                                        if c == 1 {
                                            var minDC: Int32 = 0
                                            var maxDC: Int32 = 0
                                            scratch.large.dc.withUnsafeBufferPointer { largeDCBuf in
                                                let ldc = largeDCBuf.baseAddress!
                                                let d0 = Int32((Double(ldc[0]) * dcScaleC).rounded())
                                                cDC[0] = d0
                                                minDC = d0
                                                maxDC = d0
                                                for i in 1..<covered {
                                                    let d = Int32((Double(ldc[i]) * dcScaleC).rounded())
                                                    cDC[i] = d
                                                    if d < minDC { minDC = d }
                                                    if d > maxDC { maxDC = d }
                                                }
                                            }
                                            dcHet = Double(maxDC - minDC) * Double(covered)
                                            let dcBound = dcHet + fixedBaseCost
                                            if allowTie ? (dcBound > maxCost) : (dcBound >= maxCost) {
                                                pruned = true
                                                prunedCost = dcBound
                                                break
                                            }
                                        } else {
                                            scratch.large.dc.withUnsafeBufferPointer { largeDCBuf in
                                                let ldc = largeDCBuf.baseAddress!
                                                for i in 0..<covered {
                                                    cDC[i] = Int32((Double(ldc[i]) * dcScaleC).rounded())
                                                }
                                            }
                                        }

                                        plan.transposeCoefficientsUnchecked(workspace: &scratch.large)

                                        let wBase = wPtr + c * count
                                        let cAC = acPtr + c * count
                                        scratch.large.coefficients.withUnsafeBufferPointer { coeffBuf in
                                            let coeffPtr = coeffBuf.baseAddress!
                                            for ny in 0..<llfRows {
                                                let rowOff = ny * normCols
                                                for nx in 0..<llfCols {
                                                    cAC[rowOff + nx] = 0
                                                }
                                                for pos in (rowOff + llfCols)..<(rowOff + normCols) {
                                                    let q = Int32((Double(coeffPtr[pos]) * Double(wBase[pos]) * qScale).rounded())
                                                    cAC[pos] = q
                                                    if q != 0 {
                                                        nonZeroCount += 1
                                                        acEnergy += abs(Double(q))
                                                    }
                                                }
                                            }
                                            for pos in (llfRows * normCols)..<count {
                                                let q = Int32((Double(coeffPtr[pos]) * Double(wBase[pos]) * qScale).rounded())
                                                cAC[pos] = q
                                                if q != 0 {
                                                    nonZeroCount += 1
                                                    acEnergy += abs(Double(q))
                                                }
                                            }
                                        }

                                        if step < 2 {
                                            let runningHet = dcHet + Double(nonZeroCount) * spanWeight
                                            let runningCost = Double(nonZeroCount) * 3.5 + acEnergy * 0.25 + runningHet + fixedBaseCost
                                            if allowTie ? (runningCost > maxCost) : (runningCost >= maxCost) {
                                                pruned = true
                                                prunedCost = runningCost
                                                break
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if pruned {
                    return (nil, prunedCost)
                }

                let heterogeneity = dcHet + Double(nonZeroCount) * spanWeight
                let cost = Double(nonZeroCount) * 3.5 + acEnergy * 0.25 + heterogeneity + fixedBaseCost
                if allowTie ? (cost > maxCost) : (cost >= maxCost) {
                    return (nil, cost)
                }

                let leafDC = [
                    Array(scratch.candDC[0..<covered]),
                    Array(scratch.candDC[covered..<(2 * covered)]),
                    Array(scratch.candDC[(2 * covered)..<(3 * covered)])
                ]
                let leafAC = [
                    Array(scratch.candAC[0..<count]),
                    Array(scratch.candAC[count..<(2 * count)]),
                    Array(scratch.candAC[(2 * count)..<(3 * count)])
                ]
                return (
                    SelectedLeaf(
                        identifier: id,
                        x: cx,
                        y: cy,
                        cellsX: cellsW,
                        cellsY: cellsH,
                        quantisation: regionQF,
                        dc: leafDC,
                        ac: leafAC,
                        cost: cost
                    ),
                    cost
                )
            }

            func selectBest1x1(cx: Int, cy: Int) -> (leaves: [SelectedLeaf], cost: Double) {
                let localX0 = (cx - cellX0) * 8
                let localY0 = (cy - cellY0) * 8

                scratch.tilePlanes.withUnsafeBufferPointer { tileBuf in
                    scratch.cellPatch3x64.withUnsafeMutableBufferPointer { cellBuf in
                        let tileBase = tileBuf.baseAddress!
                        let cellPtr = cellBuf.baseAddress!
                        for c in 0..<3 {
                            let src = tileBase + c * 4096 + localY0 * 64 + localX0
                            let dst = cellPtr + c * 64
                            for y in 0..<8 {
                                (dst + y * 8).update(from: src + y * 64, count: 8)
                            }
                        }
                    }
                }

                var bestID = 0
                var bestCost = Double.infinity
                var cached4x4Mask: UInt8 = 0
                var cached4x8Mask: UInt8 = 0

                @inline(__always)
                func eval1x1Candidate(_ id: Int, intoBest: Bool, maxCost: Double) -> Double {
                    let weights = immutableWeights[id]!
                    let sizePenalty = (id == 0) ? 0.0 : 0.5
                    let fixedBase = 1.0 + sizePenalty
                    var acEnergy = 0.0
                    var nonZeroCount = 0

                    scratch.cellPatch3x64.withUnsafeBufferPointer { cellBuf in
                        weights.withUnsafeBufferPointer { wBuf in
                            scratch.cached4x4.withUnsafeMutableBufferPointer { c4x4Buf in
                                scratch.cached4x8.withUnsafeMutableBufferPointer { c4x8Buf in
                                    let cellPtr = cellBuf.baseAddress!
                                    let wPtr = wBuf.baseAddress!
                                    let c4x4Ptr = c4x4Buf.baseAddress!
                                    let c4x8Ptr = c4x8Buf.baseAddress!

                                    let isAFV = (id >= 14 && id <= 17)
                                    let use4x4Cache = (id == 3 || isAFV)
                                    let use4x8Cache = (id == 12 || isAFV)
                                    let channelOrder = (1, 0, 2)

                                    for step in 0..<3 {
                                        let c = step == 0 ? channelOrder.0 : (step == 1 ? channelOrder.1 : channelOrder.2)
                                        let cBit: UInt8 = 1 << c
                                        if isAFV {
                                            if (cached4x4Mask & cBit) == 0 {
                                                smallPlan.applyUnchecked(
                                                    cellPtr + c * 64,
                                                    identifier: 3,
                                                    workspace: &scratch.small,
                                                    quad4x4Cache: c4x4Ptr + c * 64,
                                                    half4x8Cache: nil
                                                )
                                                cached4x4Mask |= cBit
                                            }
                                            if (cached4x8Mask & cBit) == 0 {
                                                smallPlan.applyUnchecked(
                                                    cellPtr + c * 64,
                                                    identifier: 12,
                                                    workspace: &scratch.small,
                                                    quad4x4Cache: nil,
                                                    half4x8Cache: c4x8Ptr + c * 64
                                                )
                                                cached4x8Mask |= cBit
                                            }
                                        }
                                        smallPlan.applyUnchecked(
                                            cellPtr + c * 64,
                                            identifier: id,
                                            workspace: &scratch.small,
                                            quad4x4Cache: use4x4Cache ? (c4x4Ptr + c * 64) : nil,
                                            half4x8Cache: use4x8Cache ? (c4x8Ptr + c * 64) : nil
                                        )
                                        if id == 3 { cached4x4Mask |= cBit }
                                        if id == 12 { cached4x8Mask |= cBit }

                                        let dcScaleC = dcScales[c]
                                        let wBase = wPtr + c * 64
                                        scratch.small.output.withUnsafeBufferPointer { outBuf in
                                            let outPtr = outBuf.baseAddress!
                                            let dcQ = Int32((Double(outPtr[0]) * dcScaleC).rounded())
                                            if intoBest {
                                                scratch.bestDC1x1[c] = dcQ
                                                scratch.bestAC1x1[c * 64] = 0
                                                for pos in 1..<64 {
                                                    let q = Int32((Double(outPtr[pos]) * Double(wBase[pos]) * qScale).rounded())
                                                    scratch.bestAC1x1[c * 64 + pos] = q
                                                    if q != 0 {
                                                        nonZeroCount += 1
                                                        acEnergy += abs(Double(q))
                                                    }
                                                }
                                            } else {
                                                scratch.candDC[c] = dcQ
                                                scratch.candAC[c * 64] = 0
                                                for pos in 1..<64 {
                                                    let q = Int32((Double(outPtr[pos]) * Double(wBase[pos]) * qScale).rounded())
                                                    scratch.candAC[c * 64 + pos] = q
                                                    if q != 0 {
                                                        nonZeroCount += 1
                                                        acEnergy += abs(Double(q))
                                                    }
                                                }
                                            }
                                        }

                                        if step < 2 {
                                            let partial = Double(nonZeroCount) * 3.5 + acEnergy * 0.25 + fixedBase
                                            if partial >= maxCost {
                                                break
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return Double(nonZeroCount) * 3.5 + acEnergy * 0.25 + fixedBase
                }

                bestCost = eval1x1Candidate(0, intoBest: true, maxCost: .infinity)
                if bestCost > 6.5 {
                    for id in [1, 2, 3, 12, 13, 14, 15, 16, 17] {
                        let candCost = eval1x1Candidate(id, intoBest: false, maxCost: bestCost - 0.5)
                        if candCost + 0.5 < bestCost {
                            bestCost = candCost
                            bestID = id
                            scratch.bestDC1x1[0] = scratch.candDC[0]
                            scratch.bestDC1x1[1] = scratch.candDC[1]
                            scratch.bestDC1x1[2] = scratch.candDC[2]
                            scratch.bestAC1x1.withUnsafeMutableBufferPointer { dst in
                                scratch.candAC.withUnsafeBufferPointer { src in
                                    dst.baseAddress!.update(from: src.baseAddress!, count: 192)
                                }
                            }
                        }
                    }
                }

                let leaf = SelectedLeaf(
                    identifier: bestID,
                    x: cx,
                    y: cy,
                    cellsX: 1,
                    cellsY: 1,
                    quantisation: regionQF,
                    dc: [[scratch.bestDC1x1[0]], [scratch.bestDC1x1[1]], [scratch.bestDC1x1[2]]],
                    ac: [
                        Array(scratch.bestAC1x1[0..<64]),
                        Array(scratch.bestAC1x1[64..<128]),
                        Array(scratch.bestAC1x1[128..<192])
                    ],
                    cost: bestCost
                )
                return ([leaf], bestCost)
            }

            func searchSubregion(cx: Int, cy: Int, w: Int, h: Int) throws -> (leaves: [SelectedLeaf], cost: Double) {
                try budget.checkpoint()
                if w == 1 && h == 1 {
                    return selectBest1x1(cx: cx, cy: cy)
                }

                var bestLeaves: [SelectedLeaf]? = nil
                var bestCost = Double.infinity

                // Quad/dyadic split into smaller transforms
                if w >= 2 && h >= 2 && w == h && (w == 8 || w == 4 || w == 2) {
                    let lx0 = (cx - cellX0) * 8
                    let ly0 = (cy - cellY0) * 8
                    let lx1 = lx0 + w * 8 - 1
                    let ly1 = ly0 + h * 8 - 1
                    let yCorner00 = scratch.tilePlanes[4096 + ly0 * 64 + lx0]
                    let yCorner11 = scratch.tilePlanes[4096 + ly1 * 64 + lx1]
                    if yCorner00 == yCorner11, let directID = directStrategyID(cellsW: w, cellsH: h) {
                        let (directOpt, directCost) = evaluateLargeTransform(id: directID, cx: cx, cy: cy, cellsW: w, cellsH: h)
                        let direct = directOpt!
                        bestLeaves = [direct]
                        bestCost = directCost
                        if directCost <= 1.25 {
                            return ([direct], directCost)
                        }
                    }

                    let half = w / 2
                    let q00 = try searchSubregion(cx: cx, cy: cy, w: half, h: half)
                    let q10 = try searchSubregion(cx: cx + half, cy: cy, w: half, h: half)
                    let q01 = try searchSubregion(cx: cx, cy: cy + half, w: half, h: half)
                    let q11 = try searchSubregion(cx: cx + half, cy: cy + half, w: half, h: half)
                    let splitCost = q00.cost + q10.cost + q01.cost + q11.cost
                    if splitCost < bestCost {
                        bestCost = splitCost
                        bestLeaves = q00.leaves + q10.leaves + q01.leaves + q11.leaves
                    }

                    if bestLeaves == nil || bestCost == splitCost, let directID = directStrategyID(cellsW: w, cellsH: h), yCorner00 != yCorner11 {
                        let (directOpt, directCost) = evaluateLargeTransform(
                            id: directID,
                            cx: cx,
                            cy: cy,
                            cellsW: w,
                            cellsH: h,
                            maxCost: bestCost,
                            allowTie: true
                        )
                        if let direct = directOpt {
                            bestCost = directCost
                            bestLeaves = [direct]
                        }
                    }

                    // Also check rectangular halves (e.g. 2x1, 1x2, 4x2, 2x4, 8x4, 4x8)
                    if let hID = directStrategyID(cellsW: w, cellsH: half) {
                        let (topOpt, topCost) = evaluateLargeTransform(id: hID, cx: cx, cy: cy, cellsW: w, cellsH: half, maxCost: bestCost)
                        if let top = topOpt {
                            let (botOpt, botCost) = evaluateLargeTransform(id: hID, cx: cx, cy: cy + half, cellsW: w, cellsH: half, maxCost: bestCost - topCost)
                            if let bot = botOpt {
                                bestCost = topCost + botCost
                                bestLeaves = [top, bot]
                            }
                        }
                    }
                    if let vID = directStrategyID(cellsW: half, cellsH: h) {
                        let (leftOpt, leftCost) = evaluateLargeTransform(id: vID, cx: cx, cy: cy, cellsW: half, cellsH: h, maxCost: bestCost)
                        if let left = leftOpt {
                            let (rightOpt, rightCost) = evaluateLargeTransform(id: vID, cx: cx + half, cy: cy, cellsW: half, cellsH: h, maxCost: bestCost - leftCost)
                            if let right = rightOpt {
                                bestCost = leftCost + rightCost
                                bestLeaves = [left, right]
                            }
                        }
                    }
                } else {
                    if let directID = directStrategyID(cellsW: w, cellsH: h) {
                        let (directOpt, directCost) = evaluateLargeTransform(id: directID, cx: cx, cy: cy, cellsW: w, cellsH: h)
                        let direct = directOpt!
                        bestLeaves = [direct]
                        bestCost = directCost
                        if directCost <= 1.25 {
                            return ([direct], directCost)
                        }
                    }
                    // Non-power-of-two partial edge region: greedily tile in raster order
                    var covered = [Bool](repeating: false, count: w * h)
                    var leaves: [SelectedLeaf] = []
                    var totalCost = 0.0
                    for ly in 0..<h {
                        for lx in 0..<w {
                            if covered[ly * w + lx] { continue }
                            let remW = w - lx
                            let remH = h - ly
                            let subW: Int
                            let subH: Int
                            if remW >= 4 && remH >= 4 {
                                subW = 4; subH = 4
                            } else if remW >= 2 && remH >= 2 {
                                subW = 2; subH = 2
                            } else if remW >= 2 && remH == 1 {
                                subW = 2; subH = 1
                            } else if remW == 1 && remH >= 2 {
                                subW = 1; subH = 2
                            } else {
                                subW = 1; subH = 1
                            }
                            let sub: (leaves: [SelectedLeaf], cost: Double)
                            if subW == subH {
                                sub = try searchSubregion(cx: cx + lx, cy: cy + ly, w: subW, h: subH)
                            } else if let rectID = directStrategyID(cellsW: subW, cellsH: subH) {
                                let (rectOpt, rectCost) = evaluateLargeTransform(id: rectID, cx: cx + lx, cy: cy + ly, cellsW: subW, cellsH: subH)
                                let rectLeaf = rectOpt!
                                var singleLeaves: [SelectedLeaf] = []
                                var singleCost = 0.0
                                for sy in 0..<subH {
                                    for sx in 0..<subW {
                                        let s = try searchSubregion(cx: cx + lx + sx, cy: cy + ly + sy, w: 1, h: 1)
                                        singleLeaves.append(contentsOf: s.leaves)
                                        singleCost += s.cost
                                    }
                                }
                                if rectCost <= singleCost {
                                    sub = ([rectLeaf], rectCost)
                                } else {
                                    sub = (singleLeaves, singleCost)
                                }
                            } else {
                                sub = try searchSubregion(cx: cx + lx, cy: cy + ly, w: 1, h: 1)
                            }
                            leaves.append(contentsOf: sub.leaves)
                            totalCost += sub.cost
                            for sy in 0..<subH {
                                for sx in 0..<subW {
                                    covered[(ly + sy) * w + (lx + sx)] = true
                                }
                            }
                        }
                    }
                    bestLeaves = leaves
                    bestCost = totalCost
                }

                return (bestLeaves ?? [], bestCost)
            }

            let selected = try searchSubregion(cx: cellX0, cy: cellY0, w: tileCellsX, h: tileCellsY)
            return TileAnalysisResult(leaves: selected.leaves)
        }

        // Execute tile batches with bounded worker scratch sets
        if scratchCount <= 1 || totalTiles <= 1 {
            for tileIndex in 0..<totalTiles {
                tileResults[tileIndex] = try processTile(tileIndex, scratch: &scratches[0])
            }
        } else if tilesX == 1 {
            let audit = ScalarStorageAudit.current
            var batchStart = 0
            while batchStart < tilesY {
                let batchTiles = min(scratchCount, tilesY - batchStart)
                if batchTiles == 1 {
                    tileResults[batchStart] = try processTile(batchStart, scratch: &scratches[0])
                } else {
                    let slotMutex = PackageMutex<([WorkerScratch], [TileAnalysisResult?], (any Error)?)>((scratches, Array(repeating: nil, count: batchTiles), nil))
                    let startTile = batchStart
                    DispatchQueue.concurrentPerform(iterations: batchTiles) { jobIndex in
                        audit?.workerStarted()
                        defer { audit?.workerCompleted() }
                        var localScratch = slotMutex.withLock { state -> WorkerScratch in
                            state.0[jobIndex]
                        }
                        do {
                            let res = try processTile(startTile + jobIndex, scratch: &localScratch)
                            slotMutex.withLock { state in
                                state.0[jobIndex] = localScratch
                                state.1[jobIndex] = res
                            }
                        } catch {
                            slotMutex.withLock { state in
                                state.0[jobIndex] = localScratch
                                if state.2 == nil { state.2 = error }
                            }
                        }
                    }
                    let (updatedScratches, batchOut, batchErr) = slotMutex.withLock { $0 }
                    scratches = updatedScratches
                    if let batchErr { throw batchErr }
                    for i in 0..<batchTiles {
                        tileResults[startTile + i] = batchOut[i]
                    }
                }
                batchStart += batchTiles
            }
        } else {
            let audit = ScalarStorageAudit.current
            let jobsInRow = min(tilesX, scratchCount)
            for ty in 0..<tilesY {
                let rowStart = ty * tilesX
                let slotMutex = PackageMutex<([WorkerScratch], [TileAnalysisResult?], (any Error)?)>((scratches, Array(repeating: nil, count: tilesX), nil))
                DispatchQueue.concurrentPerform(iterations: jobsInRow) { jobIndex in
                    audit?.workerStarted()
                    defer { audit?.workerCompleted() }
                    var localScratch = slotMutex.withLock { state -> WorkerScratch in
                        state.0[jobIndex]
                    }
                    var firstErr: (any Error)? = nil
                    var localOut: [(Int, TileAnalysisResult)] = []
                    for tx in stride(from: jobIndex, to: tilesX, by: jobsInRow) {
                        do {
                            let res = try processTile(rowStart + tx, scratch: &localScratch)
                            localOut.append((tx, res))
                        } catch {
                            if firstErr == nil { firstErr = error }
                            break
                        }
                    }
                    slotMutex.withLock { state in
                        state.0[jobIndex] = localScratch
                        for (tx, res) in localOut {
                            state.1[tx] = res
                        }
                        if let firstErr, state.2 == nil {
                            state.2 = firstErr
                        }
                    }
                }
                let (updatedScratches, rowOut, rowErr) = slotMutex.withLock { $0 }
                scratches = updatedScratches
                if let rowErr { throw rowErr }
                for tx in 0..<tilesX {
                    tileResults[rowStart + tx] = rowOut[tx]
                }
            }
        }

        // Order all selected leaves in raster order of top-left block (y * bx + x)
        var leafAtBlock = [SelectedLeaf?](repeating: nil, count: totalBlocks)
        for tr in tileResults {
            guard let tr else { continue }
            for leaf in tr.leaves {
                leafAtBlock[leaf.y * bx + leaf.x] = leaf
            }
        }

        var strategies: [Int32] = []
        var quantisation: [Int32] = []
        var transforms: [VarDCTStrategyMap.Transform] = []
        var dc = [
            [Int32](repeating: 0, count: totalBlocks),
            [Int32](repeating: 0, count: totalBlocks),
            [Int32](repeating: 0, count: totalBlocks)
        ]
        var ac = [
            [Int32](repeating: 0, count: totalCoefficients),
            [Int32](repeating: 0, count: totalCoefficients),
            [Int32](repeating: 0, count: totalCoefficients)
        ]

        var currentOffset = 0
        for byIdx in 0..<by {
            for bxIdx in 0..<bx {
                guard let leaf = leafAtBlock[byIdx * bx + bxIdx] else { continue }
                let count = leaf.cellsX * leaf.cellsY * 64
                strategies.append(Int32(leaf.identifier))
                quantisation.append(leaf.quantisation)
                transforms.append(
                    VarDCTStrategyMap.Transform(
                        identifier: leaf.identifier,
                        x: leaf.x,
                        y: leaf.y,
                        cellsX: leaf.cellsX,
                        cellsY: leaf.cellsY,
                        quantisation: UInt32(leaf.quantisation),
                        coefficientOffset: currentOffset
                    )
                )
                for c in 0..<3 {
                    dc[c].withUnsafeMutableBufferPointer { dcBuf in
                        leaf.dc[c].withUnsafeBufferPointer { ldcBuf in
                            let dcPtr = dcBuf.baseAddress!
                            let ldcPtr = ldcBuf.baseAddress!
                            for ly in 0..<leaf.cellsY {
                                (dcPtr + (leaf.y + ly) * bx + leaf.x).update(
                                    from: ldcPtr + ly * leaf.cellsX,
                                    count: leaf.cellsX
                                )
                            }
                        }
                    }
                    ac[c].withUnsafeMutableBufferPointer { acBuf in
                        leaf.ac[c].withUnsafeBufferPointer { lacBuf in
                            (acBuf.baseAddress! + currentOffset).update(from: lacBuf.baseAddress!, count: count)
                        }
                    }
                }
                currentOffset += count
            }
        }

        return Result(
            strategies: strategies,
            quantisation: quantisation,
            dc: dc,
            ac: ac,
            transforms: transforms
        )
    }

    @inline(__always)
    private static func columns(for identifier: Int) -> Int {
        VarDCTLargeAnalysis.dimensions(for: identifier)?.columns ?? 8
    }

    @inline(__always)
    private static func directStrategyID(cellsW: Int, cellsH: Int) -> Int? {
        switch (cellsW, cellsH) {
        case (1, 1): return 0
        case (2, 2): return 4
        case (4, 4): return 5
        case (1, 2): return 6
        case (2, 1): return 7
        case (1, 4): return 8
        case (4, 1): return 9
        case (2, 4): return 10
        case (4, 2): return 11
        case (8, 8): return 18
        case (4, 8): return 19
        case (8, 4): return 20
        default: return nil
        }
    }
}
