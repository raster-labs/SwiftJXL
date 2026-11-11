// SPDX-License-Identifier: Apache-2.0
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

        init(budget: ScalarOperationBudget) throws {
            self.small = try VarDCTSmallAnalysis.Workspace(budget: budget)
            self.large = try VarDCTLargeAnalysis.Workspace(capacity: 4096, budget: budget)
            try budget.reserveWorkspace((192 + 4096) * MemoryLayout<Float>.stride)
            self.patch3x64 = [Float](repeating: 0, count: 192)
            self.patchLarge = [Float](repeating: 0, count: 4096)
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
        let immutableOrders = orderTables

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

            func evaluateSingleTransform(
                id: Int,
                cx: Int,
                cy: Int,
                cellsW: Int,
                cellsH: Int
            ) throws -> SelectedLeaf {
                let rows = cellsH * 8
                let cols = cellsW * 8
                let count = rows * cols
                let covered = cellsW * cellsH
                let weights = immutableWeights[id]!
                let order = immutableOrders[id]!
                let qScale = acScaleBase * Double(regionQF)

                var leafDC = [[Int32]](repeating: [Int32](repeating: 0, count: covered), count: 3)
                var leafAC = [[Int32]](repeating: [Int32](repeating: 0, count: count), count: 3)
                var acEnergy = 0.0
                var nonZeroCount = 0

                for c in 0..<3 {
                    for y in 0..<rows {
                        let sy = min(height - 1, cy * 8 + y) * width
                        let dstRow = y * cols
                        for x in 0..<cols {
                            let sx = min(width - 1, cx * 8 + x)
                            let idx = sy + sx
                            scratch.patchLarge[dstRow + x] = (c == 2)
                                ? (ImmutablePlanes[2][idx] - ImmutablePlanes[1][idx])
                                : ImmutablePlanes[c][idx]
                        }
                    }

                    if covered > 1 {
                        let plan = immutableLargePlans[id]!
                        let slice = UnsafeBufferPointer(
                            start: scratch.patchLarge.withUnsafeBufferPointer { $0.baseAddress },
                            count: count
                        )
                        try plan.apply(slice, workspace: &scratch.large)
                        for i in 0..<covered {
                            leafDC[c][i] = Int32((Double(scratch.large.dcValue(at: i)) * dcScales[c]).rounded())
                        }
                        let wBase = c * count
                        for k in covered..<count {
                            let pos = order[k]
                            let q = Int32((Double(scratch.large.coefficient(at: pos)) * Double(weights[wBase + pos]) * qScale).rounded())
                            leafAC[c][pos] = q
                            if q != 0 {
                                nonZeroCount += 1
                                acEnergy += abs(Double(q))
                            }
                        }
                    } else {
                        let slice = UnsafeBufferPointer(
                            start: scratch.patchLarge.withUnsafeBufferPointer { $0.baseAddress },
                            count: 64
                        )
                        try smallPlan.apply(slice, identifier: id, workspace: &scratch.small)
                        leafDC[c][0] = Int32((Double(scratch.small.value(at: 0)) * dcScales[c]).rounded())
                        let wBase = c * 64
                        for k in 1..<64 {
                            let pos = order[k]
                            let q = Int32((Double(scratch.small.value(at: pos)) * Double(weights[wBase + pos]) * qScale).rounded())
                            leafAC[c][pos] = q
                            if q != 0 {
                                nonZeroCount += 1
                                acEnergy += abs(Double(q))
                            }
                        }
                    }
                }

                // Rate-distortion proxy: non-zero count + L1 magnitude + heterogeneity penalty for multi-cell transforms
                var heterogeneity = 0.0
                if covered > 1 {
                    var minDC = leafDC[1][0]
                    var maxDC = leafDC[1][0]
                    for i in 1..<covered {
                        let v = leafDC[1][i]
                        if v < minDC { minDC = v }
                        if v > maxDC { maxDC = v }
                    }
                    heterogeneity = Double(maxDC - minDC) * Double(covered) + Double(nonZeroCount) * Double(cellsW + cellsH)
                }
                let transformOverhead = 1.0
                let sizePenalty = (id == 0 || id == 4 || id == 5 || id == 18) ? 0.0 : 0.5
                let cost = Double(nonZeroCount) * 3.5 + acEnergy * 0.25 + heterogeneity + transformOverhead + sizePenalty
                return SelectedLeaf(
                    identifier: id,
                    x: cx,
                    y: cy,
                    cellsX: cellsW,
                    cellsY: cellsH,
                    quantisation: regionQF,
                    dc: leafDC,
                    ac: leafAC,
                    cost: cost
                )
            }

            func searchSubregion(cx: Int, cy: Int, w: Int, h: Int) throws -> (leaves: [SelectedLeaf], cost: Double) {
                try budget.checkpoint()
                if w == 1 && h == 1 {
                    var best = try evaluateSingleTransform(id: 0, cx: cx, cy: cy, cellsW: 1, cellsH: 1)
                    if best.cost > 6.5 {
                        for id in [1, 2, 3, 12, 13, 14, 15, 16, 17] {
                            let cand = try evaluateSingleTransform(id: id, cx: cx, cy: cy, cellsW: 1, cellsH: 1)
                            if cand.cost + 0.5 < best.cost {
                                best = cand
                            }
                        }
                    }
                    return ([best], best.cost)
                }

                // Direct single-transform candidate if supported for (w, h)
                var bestLeaves: [SelectedLeaf]? = nil
                var bestCost = Double.infinity

                if let directID = directStrategyID(cellsW: w, cellsH: h) {
                    let direct = try evaluateSingleTransform(id: directID, cx: cx, cy: cy, cellsW: w, cellsH: h)
                    bestLeaves = [direct]
                    bestCost = direct.cost
                    // Fast exit for completely smooth regions (all AC == 0 and uniform DC)
                    if direct.cost <= 1.25 {
                        return ([direct], direct.cost)
                    }
                }

                // Quad/dyadic split into smaller transforms
                if w >= 2 && h >= 2 && w == h && (w == 8 || w == 4 || w == 2) {
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

                    // Also check rectangular halves (e.g. 2x1, 1x2, 4x2, 2x4, 8x4, 4x8)
                    if let hID = directStrategyID(cellsW: w, cellsH: half) {
                        let top = try evaluateSingleTransform(id: hID, cx: cx, cy: cy, cellsW: w, cellsH: half)
                        let bot = try evaluateSingleTransform(id: hID, cx: cx, cy: cy + half, cellsW: w, cellsH: half)
                        let hCost = top.cost + bot.cost
                        if hCost < bestCost {
                            bestCost = hCost
                            bestLeaves = [top, bot]
                        }
                    }
                    if let vID = directStrategyID(cellsW: half, cellsH: h) {
                        let left = try evaluateSingleTransform(id: vID, cx: cx, cy: cy, cellsW: half, cellsH: h)
                        let right = try evaluateSingleTransform(id: vID, cx: cx + half, cy: cy, cellsW: half, cellsH: h)
                        let vCost = left.cost + right.cost
                        if vCost < bestCost {
                            bestCost = vCost
                            bestLeaves = [left, right]
                        }
                    }
                } else {
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
                                let rectLeaf = try evaluateSingleTransform(id: rectID, cx: cx + lx, cy: cy + ly, cellsW: subW, cellsH: subH)
                                var singleLeaves: [SelectedLeaf] = []
                                var singleCost = 0.0
                                for sy in 0..<subH {
                                    for sx in 0..<subW {
                                        let s = try searchSubregion(cx: cx + lx + sx, cy: cy + ly + sy, w: 1, h: 1)
                                        singleLeaves.append(contentsOf: s.leaves)
                                        singleCost += s.cost
                                    }
                                }
                                if rectLeaf.cost <= singleCost {
                                    sub = ([rectLeaf], rectLeaf.cost)
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
                    for ly in 0..<leaf.cellsY {
                        for lx in 0..<leaf.cellsX {
                            dc[c][(leaf.y + ly) * bx + (leaf.x + lx)] = leaf.dc[c][ly * leaf.cellsX + lx]
                        }
                    }
                    for i in 0..<count {
                        ac[c][currentOffset + i] = leaf.ac[c][i]
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
