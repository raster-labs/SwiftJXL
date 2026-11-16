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

        init(budget: ScalarOperationBudget) throws {
            self.small = try VarDCTSmallAnalysis.Workspace(budget: budget)
            self.large = try VarDCTLargeAnalysis.Workspace(capacity: 4096, budget: budget)
            try budget.reserveWorkspace((192 + 4096) * MemoryLayout<Float>.stride)
            self.patch3x64 = [Float](repeating: 0, count: 192)
            self.patchLarge = [Float](repeating: 0, count: 4096)
        }
    }

    private struct LeafSpec: Sendable {
        var identifier: Int16
        var x: Int16
        var y: Int16
        var cellsX: UInt8
        var cellsY: UInt8
        var quantisation: Int32
        var acTileOffset: Int32

        static let empty = LeafSpec(
            identifier: -1, x: 0, y: 0, cellsX: 0, cellsY: 0, quantisation: 5, acTileOffset: 0
        )
    }

    private struct TileAnalysisResult: Sendable {
        let leaves: [LeafSpec]
        let dcFlat: [Int32]   // 3 * tileCellsX * tileCellsY
        let acFlat: [Int32]   // 3 * totalTileCoefficients
    }

    private typealias Grid64 = (
        LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec,
        LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec,
        LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec,
        LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec,
        LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec,
        LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec,
        LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec,
        LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec, LeafSpec
    )

    @inline(__always)
    private static func emptyGrid64() -> Grid64 {
        let e = LeafSpec.empty
        return (
            e, e, e, e, e, e, e, e,
            e, e, e, e, e, e, e, e,
            e, e, e, e, e, e, e, e,
            e, e, e, e, e, e, e, e,
            e, e, e, e, e, e, e, e,
            e, e, e, e, e, e, e, e,
            e, e, e, e, e, e, e, e,
            e, e, e, e, e, e, e, e
        )
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

        let isLargeGrid = tilesX >= 8 && tilesY >= 8 &&
            budget.maximumWorkspaceBytes - budget.reservedWorkspaceBytes >= 2 * 1024 * 1024
        let maxWorkerCap = isLargeGrid ? 8 : 3
        let workerCap = min(maxWorkerCap, max(1, budget.maximumWorkers))
        let scratchCount = totalTiles > 1 ? min(workerCap, totalTiles) : 1
        var scratches: [WorkerScratch] = []
        scratches.reserveCapacity(scratchCount)
        for _ in 0..<scratchCount {
            scratches.append(try WorkerScratch(budget: budget))
        }

        let dcScale0 = Double(scale) * 17.0 * 4096.0 / 65536.0
        let dcScale1 = Double(scale) * 17.0 * 512.0 / 65536.0
        let dcScale2 = Double(scale) * 17.0 * 256.0 / 65536.0
        let dcScales = (dcScale0, dcScale1, dcScale2)
        let acScaleBase = Double(scale) / 65536.0
        var tileResults = [TileAnalysisResult?](repeating: nil, count: totalTiles)
        let immutablePlanes = planes
        let immutableLargePlans = largePlans
        let immutableWeights = weightTables
        let immutableOrders = orderTables

        @inline(__always)
        @Sendable
        func dcScale(for channel: Int) -> Double {
            switch channel {
            case 0: return dcScales.0
            case 1: return dcScales.1
            default: return dcScales.2
            }
        }

        @Sendable
        func processTile(_ tileIndex: Int, scratch: inout WorkerScratch) throws -> TileAnalysisResult {
            try budget.checkpoint()
            let tx = tileIndex % tilesX
            let ty = tileIndex / tilesX
            let cellX0 = tx * 8
            let cellY0 = ty * 8
            let tileCellsX = min(8, bx - cellX0)
            let tileCellsY = min(8, by - cellY0)
            let tileBlocks = tileCellsX * tileCellsY

            return try immutablePlanes[0].withUnsafeBufferPointer { p0Buf in
                try immutablePlanes[1].withUnsafeBufferPointer { p1Buf in
                    try immutablePlanes[2].withUnsafeBufferPointer { p2Buf in
                        let p0 = p0Buf.baseAddress!
                        let p1 = p1Buf.baseAddress!
                        let p2 = p2Buf.baseAddress!

                        // Validate finiteness of all samples in this tile up front once
                        let pyStart = cellY0 * 8
                        let pyEnd = min(height, (cellY0 + tileCellsY) * 8)
                        let pxStart = cellX0 * 8
                        let pxEnd = min(width, (cellX0 + tileCellsX) * 8)
                        for py in pyStart..<pyEnd {
                            let row = py &* width
                            for px in pxStart..<pxEnd {
                                let idx = row &+ px
                                guard p0[idx].isFinite, p1[idx].isFinite, p2[idx].isFinite else {
                                    throw VarDCTError.nonFiniteSample
                                }
                            }
                        }

                        // Compute region quantisation from top-left 8x8 cell of the tile
                        let regionQF: Int32
                        if adaptiveQuantisation {
                            scratch.patch3x64.withUnsafeMutableBufferPointer { p64Buf in
                                let dst = p64Buf.baseAddress!
                                for y in 0..<8 {
                                    let sy = min(height - 1, cellY0 * 8 + y) * width
                                    let rOff = y &* 8
                                    for x in 0..<8 {
                                        let idx = sy &+ min(width - 1, cellX0 * 8 + x)
                                        dst[rOff &+ x] = p0[idx]
                                        dst[64 &+ rOff &+ x] = p1[idx]
                                        dst[128 &+ rOff &+ x] = p2[idx]
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

                        // Pure cost-only evaluation: zero heap allocations for candidate transforms!
                        func evaluateTransformCost(
                            id: Int,
                            cx: Int,
                            cy: Int,
                            cellsW: Int,
                            cellsH: Int
                        ) -> Double {
                            let rows = cellsH &* 8
                            let cols = cellsW &* 8
                            let count = rows &* cols
                            let covered = cellsW &* cellsH
                            var acEnergy = 0.0
                            var nonZeroCount = 0
                            var minDCY: Int32 = 0
                            var maxDCY: Int32 = 0

                            immutableWeights[id]!.withUnsafeBufferPointer { wBuf in
                                immutableOrders[id]!.withUnsafeBufferPointer { oBuf in
                                    let weights = wBuf.baseAddress!
                                    let order = oBuf.baseAddress!

                                    for c in 0..<3 {
                                        scratch.patchLarge.withUnsafeMutableBufferPointer { patchBuf in
                                            let dst = patchBuf.baseAddress!
                                            let cPlane = (c == 0) ? p0 : (c == 1 ? p1 : p2)
                                            if c == 2 {
                                                for y in 0..<rows {
                                                    let sy = min(height - 1, cy * 8 + y) * width
                                                    let dstRow = y &* cols
                                                    let baseX = cx * 8
                                                    if baseX + cols <= width {
                                                        let srcBase = sy &+ baseX
                                                        for x in 0..<cols {
                                                            dst[dstRow &+ x] = p2[srcBase &+ x] - p1[srcBase &+ x]
                                                        }
                                                    } else {
                                                        for x in 0..<cols {
                                                            let idx = sy &+ min(width - 1, baseX &+ x)
                                                            dst[dstRow &+ x] = p2[idx] - p1[idx]
                                                        }
                                                    }
                                                }
                                            } else {
                                                for y in 0..<rows {
                                                    let sy = min(height - 1, cy * 8 + y) * width
                                                    let dstRow = y &* cols
                                                    let baseX = cx * 8
                                                    if baseX + cols <= width {
                                                        dst.advanced(by: dstRow).update(from: cPlane.advanced(by: sy &+ baseX), count: cols)
                                                    } else {
                                                        for x in 0..<cols {
                                                            dst[dstRow &+ x] = cPlane[sy &+ min(width - 1, baseX &+ x)]
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        let dScale = dcScale(for: c)
                                        if covered > 1 {
                                            let plan = immutableLargePlans[id]!
                                            scratch.patchLarge.withUnsafeBufferPointer { patchBuf in
                                                plan.applyFast(patchBuf.baseAddress!, workspace: &scratch.large)
                                            }
                                            scratch.large.withBuffers { coeffBuf, dcBuf in
                                                let coeffs = coeffBuf.baseAddress!
                                                let dcs = dcBuf.baseAddress!
                                                if c == 1 {
                                                    let dc0 = Int32((Double(dcs[0]) * dScale).rounded())
                                                    minDCY = dc0
                                                    maxDCY = dc0
                                                    for i in 1..<covered {
                                                        let v = Int32((Double(dcs[i]) * dScale).rounded())
                                                        if v < minDCY { minDCY = v }
                                                        if v > maxDCY { maxDCY = v }
                                                    }
                                                }
                                                let wBase = c &* count
                                                for k in covered..<count {
                                                    let pos = order[k]
                                                    let q = Int32((Double(coeffs[pos]) * Double(weights[wBase &+ pos]) * qScale).rounded())
                                                    if q != 0 {
                                                        nonZeroCount &+= 1
                                                        acEnergy += abs(Double(q))
                                                    }
                                                }
                                            }
                                        } else {
                                            scratch.patchLarge.withUnsafeBufferPointer { patchBuf in
                                                smallPlan.applyFast(patchBuf.baseAddress!, identifier: id, workspace: &scratch.small)
                                            }
                                            scratch.small.withOutputBuffer { outBuf in
                                                let coeffs = outBuf.baseAddress!
                                                let wBase = c &* 64
                                                for k in 1..<64 {
                                                    let pos = order[k]
                                                    let q = Int32((Double(coeffs[pos]) * Double(weights[wBase &+ pos]) * qScale).rounded())
                                                    if q != 0 {
                                                        nonZeroCount &+= 1
                                                        acEnergy += abs(Double(q))
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            var heterogeneity = 0.0
                            if covered > 1 {
                                heterogeneity = Double(maxDCY - minDCY) * Double(covered)
                                    + Double(nonZeroCount) * Double(cellsW + cellsH)
                            }
                            let transformOverhead = 1.0
                            let sizePenalty = (id == 0 || id == 4 || id == 5 || id == 18) ? 0.0 : 0.5
                            return Double(nonZeroCount) * 3.5 + acEnergy * 0.25 + heterogeneity + transformOverhead + sizePenalty
                        }

                        @inline(__always)
                        func clearSubgrid(_ grid: UnsafeMutablePointer<LeafSpec>, lx0: Int, ly0: Int, w: Int, h: Int) {
                            for ly in ly0..<(ly0 + h) {
                                let row = ly &* 8
                                for lx in lx0..<(lx0 + w) {
                                    grid[row &+ lx] = .empty
                                }
                            }
                        }

                        @inline(__always)
                        func copySubgrid(from src: UnsafePointer<LeafSpec>, into dst: UnsafeMutablePointer<LeafSpec>, lx0: Int, ly0: Int, w: Int, h: Int) {
                            for ly in ly0..<(ly0 + h) {
                                let row = ly &* 8
                                for lx in lx0..<(lx0 + w) {
                                    dst[row &+ lx] = src[row &+ lx]
                                }
                            }
                        }

                        func searchSubregion(
                            cx: Int,
                            cy: Int,
                            w: Int,
                            h: Int,
                            into dstGrid: UnsafeMutablePointer<LeafSpec>
                        ) throws -> Double {
                            try budget.checkpoint()
                            let lx0 = cx - cellX0
                            let ly0 = cy - cellY0

                            if w == 1 && h == 1 {
                                var bestID = 0
                                var bestCost = evaluateTransformCost(id: 0, cx: cx, cy: cy, cellsW: 1, cellsH: 1)
                                if bestCost > 6.5 {
                                    for id in [1, 2, 3, 12, 13, 14, 15, 16, 17] {
                                        let candCost = evaluateTransformCost(id: id, cx: cx, cy: cy, cellsW: 1, cellsH: 1)
                                        if candCost + 0.5 < bestCost {
                                            bestCost = candCost
                                            bestID = id
                                        }
                                    }
                                }
                                dstGrid[ly0 &* 8 &+ lx0] = LeafSpec(
                                    identifier: Int16(bestID),
                                    x: Int16(cx),
                                    y: Int16(cy),
                                    cellsX: 1,
                                    cellsY: 1,
                                    quantisation: regionQF,
                                    acTileOffset: 0
                                )
                                return bestCost
                            }

                            var bestCost = Double.infinity
                            clearSubgrid(dstGrid, lx0: lx0, ly0: ly0, w: w, h: h)

                            if let directID = directStrategyID(cellsW: w, cellsH: h) {
                                let directCost = evaluateTransformCost(id: directID, cx: cx, cy: cy, cellsW: w, cellsH: h)
                                bestCost = directCost
                                dstGrid[ly0 &* 8 &+ lx0] = LeafSpec(
                                    identifier: Int16(directID),
                                    x: Int16(cx),
                                    y: Int16(cy),
                                    cellsX: UInt8(w),
                                    cellsY: UInt8(h),
                                    quantisation: regionQF,
                                    acTileOffset: 0
                                )
                                if directCost <= 1.25 {
                                    return directCost
                                }
                            }

                            if w >= 2 && h >= 2 && w == h && (w == 8 || w == 4 || w == 2) {
                                let half = w / 2
                                var splitStorage = emptyGrid64()
                                let splitCost: Double = try withUnsafeMutablePointer(to: &splitStorage) { tuplePtr in
                                    let splitGrid = UnsafeMutableRawPointer(tuplePtr).assumingMemoryBound(to: LeafSpec.self)
                                    let c00 = try searchSubregion(cx: cx, cy: cy, w: half, h: half, into: splitGrid)
                                    let c10 = try searchSubregion(cx: cx + half, cy: cy, w: half, h: half, into: splitGrid)
                                    let c01 = try searchSubregion(cx: cx, cy: cy + half, w: half, h: half, into: splitGrid)
                                    let c11 = try searchSubregion(cx: cx + half, cy: cy + half, w: half, h: half, into: splitGrid)
                                    let total = c00 + c10 + c01 + c11
                                    if total < bestCost {
                                        copySubgrid(from: splitGrid, into: dstGrid, lx0: lx0, ly0: ly0, w: w, h: h)
                                    }
                                    return total
                                }
                                if splitCost < bestCost {
                                    bestCost = splitCost
                                }

                                if let hID = directStrategyID(cellsW: w, cellsH: half) {
                                    let topCost = evaluateTransformCost(id: hID, cx: cx, cy: cy, cellsW: w, cellsH: half)
                                    let botCost = evaluateTransformCost(id: hID, cx: cx, cy: cy + half, cellsW: w, cellsH: half)
                                    let hCost = topCost + botCost
                                    if hCost < bestCost {
                                        bestCost = hCost
                                        clearSubgrid(dstGrid, lx0: lx0, ly0: ly0, w: w, h: h)
                                        dstGrid[ly0 &* 8 &+ lx0] = LeafSpec(
                                            identifier: Int16(hID), x: Int16(cx), y: Int16(cy),
                                            cellsX: UInt8(w), cellsY: UInt8(half), quantisation: regionQF, acTileOffset: 0
                                        )
                                        dstGrid[(ly0 + half) &* 8 &+ lx0] = LeafSpec(
                                            identifier: Int16(hID), x: Int16(cx), y: Int16(cy + half),
                                            cellsX: UInt8(w), cellsY: UInt8(half), quantisation: regionQF, acTileOffset: 0
                                        )
                                    }
                                }

                                if let vID = directStrategyID(cellsW: half, cellsH: h) {
                                    let leftCost = evaluateTransformCost(id: vID, cx: cx, cy: cy, cellsW: half, cellsH: h)
                                    let rightCost = evaluateTransformCost(id: vID, cx: cx + half, cy: cy, cellsW: half, cellsH: h)
                                    let vCost = leftCost + rightCost
                                    if vCost < bestCost {
                                        bestCost = vCost
                                        clearSubgrid(dstGrid, lx0: lx0, ly0: ly0, w: w, h: h)
                                        dstGrid[ly0 &* 8 &+ lx0] = LeafSpec(
                                            identifier: Int16(vID), x: Int16(cx), y: Int16(cy),
                                            cellsX: UInt8(half), cellsY: UInt8(h), quantisation: regionQF, acTileOffset: 0
                                        )
                                        dstGrid[ly0 &* 8 &+ (lx0 + half)] = LeafSpec(
                                            identifier: Int16(vID), x: Int16(cx + half), y: Int16(cy),
                                            cellsX: UInt8(half), cellsY: UInt8(h), quantisation: regionQF, acTileOffset: 0
                                        )
                                    }
                                }
                            } else {
                                clearSubgrid(dstGrid, lx0: lx0, ly0: ly0, w: w, h: h)
                                var coveredMask: UInt64 = 0
                                var totalCost = 0.0
                                for ly in 0..<h {
                                    for lx in 0..<w {
                                        let bit = UInt64(1) &<< UInt64((ly0 + ly) * 8 + (lx0 + lx))
                                        if (coveredMask & bit) != 0 { continue }
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
                                        let subCost: Double
                                        if subW == subH {
                                            subCost = try searchSubregion(cx: cx + lx, cy: cy + ly, w: subW, h: subH, into: dstGrid)
                                        } else if let rectID = directStrategyID(cellsW: subW, cellsH: subH) {
                                            let rectCost = evaluateTransformCost(id: rectID, cx: cx + lx, cy: cy + ly, cellsW: subW, cellsH: subH)
                                            var singleCost = 0.0
                                            for sy in 0..<subH {
                                                for sx in 0..<subW {
                                                    singleCost += try searchSubregion(cx: cx + lx + sx, cy: cy + ly + sy, w: 1, h: 1, into: dstGrid)
                                                }
                                            }
                                            if rectCost <= singleCost {
                                                clearSubgrid(dstGrid, lx0: lx0 + lx, ly0: ly0 + ly, w: subW, h: subH)
                                                dstGrid[(ly0 + ly) &* 8 &+ (lx0 + lx)] = LeafSpec(
                                                    identifier: Int16(rectID), x: Int16(cx + lx), y: Int16(cy + ly),
                                                    cellsX: UInt8(subW), cellsY: UInt8(subH), quantisation: regionQF, acTileOffset: 0
                                                )
                                                subCost = rectCost
                                            } else {
                                                subCost = singleCost
                                            }
                                        } else {
                                            subCost = try searchSubregion(cx: cx + lx, cy: cy + ly, w: 1, h: 1, into: dstGrid)
                                        }
                                        totalCost += subCost
                                        for sy in 0..<subH {
                                            for sx in 0..<subW {
                                                coveredMask |= UInt64(1) &<< UInt64((ly0 + ly + sy) * 8 + (lx0 + lx + sx))
                                            }
                                        }
                                    }
                                }
                                bestCost = totalCost
                            }
                            return bestCost
                        }

                        var gridStorage = emptyGrid64()
                        var leaves: [LeafSpec] = []
                        leaves.reserveCapacity(tileBlocks)
                        try withUnsafeMutablePointer(to: &gridStorage) { tuplePtr in
                            let grid = UnsafeMutableRawPointer(tuplePtr).assumingMemoryBound(to: LeafSpec.self)
                            _ = try searchSubregion(cx: cellX0, cy: cellY0, w: tileCellsX, h: tileCellsY, into: grid)
                            var acOffset: Int32 = 0
                            for ly in 0..<tileCellsY {
                                for lx in 0..<tileCellsX {
                                    var spec = grid[ly &* 8 &+ lx]
                                    if spec.identifier >= 0 {
                                        spec.acTileOffset = acOffset
                                        acOffset &+= Int32(spec.cellsX) * Int32(spec.cellsY) * 64
                                        leaves.append(spec)
                                    }
                                }
                            }
                        }

                        // Materialize quantized DC and AC coefficients ONCE for the winning partition of this tile
                        let tileACCount = tileBlocks * 64
                        var dcFlat = [Int32](repeating: 0, count: 3 * tileBlocks)
                        var acFlat = [Int32](repeating: 0, count: 3 * tileACCount)

                        dcFlat.withUnsafeMutableBufferPointer { dcOutBuf in
                            acFlat.withUnsafeMutableBufferPointer { acOutBuf in
                                let dcOut = dcOutBuf.baseAddress!
                                let acOut = acOutBuf.baseAddress!

                                for spec in leaves {
                                    let id = Int(spec.identifier)
                                    let cx = Int(spec.x)
                                    let cy = Int(spec.y)
                                    let cellsW = Int(spec.cellsX)
                                    let cellsH = Int(spec.cellsY)
                                    let rows = cellsH &* 8
                                    let cols = cellsW &* 8
                                    let count = rows &* cols
                                    let covered = cellsW &* cellsH
                                    let acTileOff = Int(spec.acTileOffset)

                                    immutableWeights[id]!.withUnsafeBufferPointer { wBuf in
                                        immutableOrders[id]!.withUnsafeBufferPointer { oBuf in
                                            let weights = wBuf.baseAddress!
                                            let order = oBuf.baseAddress!

                                            for c in 0..<3 {
                                                scratch.patchLarge.withUnsafeMutableBufferPointer { patchBuf in
                                                    let dst = patchBuf.baseAddress!
                                                    let cPlane = (c == 0) ? p0 : (c == 1 ? p1 : p2)
                                                    if c == 2 {
                                                        for y in 0..<rows {
                                                            let sy = min(height - 1, cy * 8 + y) * width
                                                            let dstRow = y &* cols
                                                            let baseX = cx * 8
                                                            if baseX + cols <= width {
                                                                let srcBase = sy &+ baseX
                                                                for x in 0..<cols {
                                                                    dst[dstRow &+ x] = p2[srcBase &+ x] - p1[srcBase &+ x]
                                                                }
                                                            } else {
                                                                for x in 0..<cols {
                                                                    let idx = sy &+ min(width - 1, baseX &+ x)
                                                                    dst[dstRow &+ x] = p2[idx] - p1[idx]
                                                                }
                                                            }
                                                        }
                                                    } else {
                                                        for y in 0..<rows {
                                                            let sy = min(height - 1, cy * 8 + y) * width
                                                            let dstRow = y &* cols
                                                            let baseX = cx * 8
                                                            if baseX + cols <= width {
                                                                dst.advanced(by: dstRow).update(from: cPlane.advanced(by: sy &+ baseX), count: cols)
                                                            } else {
                                                                for x in 0..<cols {
                                                                    dst[dstRow &+ x] = cPlane[sy &+ min(width - 1, baseX &+ x)]
                                                                }
                                                            }
                                                        }
                                                    }
                                                }

                                                let dScale = dcScale(for: c)
                                                let dcChanBase = c &* tileBlocks
                                                let acChanBase = c &* tileACCount &+ acTileOff

                                                if covered > 1 {
                                                    let plan = immutableLargePlans[id]!
                                                    scratch.patchLarge.withUnsafeBufferPointer { patchBuf in
                                                        plan.applyFast(patchBuf.baseAddress!, workspace: &scratch.large)
                                                    }
                                                    scratch.large.withBuffers { coeffBuf, dcBuf in
                                                        let coeffs = coeffBuf.baseAddress!
                                                        let dcs = dcBuf.baseAddress!
                                                        for ly in 0..<cellsH {
                                                            for lx in 0..<cellsW {
                                                                let localCell = (cy - cellY0 + ly) &* tileCellsX &+ (cx - cellX0 + lx)
                                                                dcOut[dcChanBase &+ localCell] = Int32((Double(dcs[ly &* cellsW &+ lx]) * dScale).rounded())
                                                            }
                                                        }
                                                        let wBase = c &* count
                                                        for k in covered..<count {
                                                            let pos = order[k]
                                                            acOut[acChanBase &+ pos] = Int32((Double(coeffs[pos]) * Double(weights[wBase &+ pos]) * qScale).rounded())
                                                        }
                                                    }
                                                } else {
                                                    scratch.patchLarge.withUnsafeBufferPointer { patchBuf in
                                                        smallPlan.applyFast(patchBuf.baseAddress!, identifier: id, workspace: &scratch.small)
                                                    }
                                                    scratch.small.withOutputBuffer { outBuf in
                                                        let coeffs = outBuf.baseAddress!
                                                        let localCell = (cy - cellY0) &* tileCellsX &+ (cx - cellX0)
                                                        dcOut[dcChanBase &+ localCell] = Int32((Double(coeffs[0]) * dScale).rounded())
                                                        let wBase = c &* 64
                                                        for k in 1..<64 {
                                                            let pos = order[k]
                                                            acOut[acChanBase &+ pos] = Int32((Double(coeffs[pos]) * Double(weights[wBase &+ pos]) * qScale).rounded())
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        return TileAnalysisResult(leaves: leaves, dcFlat: dcFlat, acFlat: acFlat)
                    }
                }
            }
        }

        // Execute tile batches with bounded worker scratch sets
        if scratchCount <= 1 || totalTiles <= 1 {
            for tileIndex in 0..<totalTiles {
                tileResults[tileIndex] = try processTile(tileIndex, scratch: &scratches[0])
            }
        } else if isLargeGrid {
            // Single-dispatch dynamic tile work-stealing across all workers for large frames (>= 512x512)
            let audit = ScalarStorageAudit.current
            let nextTile = Atomic<Int>(0)
            let errMutex = PackageMutex<(any Error)?>(nil)
            scratches.withUnsafeMutableBufferPointer { scratchBuf in
                tileResults.withUnsafeMutableBufferPointer { resBuf in
                    let scratchBaseAddr = Int(bitPattern: scratchBuf.baseAddress!)
                    let resBaseAddr = Int(bitPattern: resBuf.baseAddress!)
                    DispatchQueue.concurrentPerform(iterations: scratchCount) { workerIndex in
                        audit?.workerStarted()
                        defer { audit?.workerCompleted() }
                        let scratchPtr = UnsafeMutablePointer<WorkerScratch>(bitPattern: scratchBaseAddr)! + workerIndex
                        let resBase = UnsafeMutablePointer<TileAnalysisResult?>(bitPattern: resBaseAddr)!
                        while true {
                            if errMutex.withLock({ $0 != nil }) { break }
                            let tileIdx = nextTile.wrappingAdd(1, ordering: .relaxed).oldValue
                            if tileIdx >= totalTiles { break }
                            do {
                                let res = try processTile(tileIdx, scratch: &scratchPtr.pointee)
                                resBase[tileIdx] = res
                            } catch {
                                errMutex.withLock { if $0 == nil { $0 = error } }
                                break
                            }
                        }
                    }
                }
            }
            if let err = errMutex.withLock({ $0 }) { throw err }
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
        var tileIdxForBlock = [Int32](repeating: -1, count: totalBlocks)
        var leafIdxForBlock = [Int32](repeating: -1, count: totalBlocks)
        var totalLeafCount = 0
        for (tIdx, trOpt) in tileResults.enumerated() {
            guard let tr = trOpt else { continue }
            totalLeafCount += tr.leaves.count
            let tx = tIdx % tilesX
            let ty = tIdx / tilesX
            let cellX0 = tx * 8
            let cellY0 = ty * 8
            let tileCellsX = min(8, bx - cellX0)
            let tileCellsY = min(8, by - cellY0)
            let tileBlocks = tileCellsX * tileCellsY
            for (lIdx, leaf) in tr.leaves.enumerated() {
                let bIndex = Int(leaf.y) * bx + Int(leaf.x)
                tileIdxForBlock[bIndex] = Int32(tIdx)
                leafIdxForBlock[bIndex] = Int32(lIdx)
            }
            _ = tileBlocks
        }

        var strategies: [Int32] = []
        strategies.reserveCapacity(totalLeafCount)
        var quantisation: [Int32] = []
        quantisation.reserveCapacity(totalLeafCount)
        var transforms: [VarDCTStrategyMap.Transform] = []
        transforms.reserveCapacity(totalLeafCount)

        var dc0 = [Int32](repeating: 0, count: totalBlocks)
        var dc1 = [Int32](repeating: 0, count: totalBlocks)
        var dc2 = [Int32](repeating: 0, count: totalBlocks)
        var ac0 = [Int32](repeating: 0, count: totalCoefficients)
        var ac1 = [Int32](repeating: 0, count: totalCoefficients)
        var ac2 = [Int32](repeating: 0, count: totalCoefficients)

        dc0.withUnsafeMutableBufferPointer { dc0Buf in
            dc1.withUnsafeMutableBufferPointer { dc1Buf in
                dc2.withUnsafeMutableBufferPointer { dc2Buf in
                    let d0 = dc0Buf.baseAddress!
                    let d1 = dc1Buf.baseAddress!
                    let d2 = dc2Buf.baseAddress!

                    // Scatter DC per tile in contiguous row runs
                    for (tIdx, trOpt) in tileResults.enumerated() {
                        guard let tr = trOpt else { continue }
                        let tx = tIdx % tilesX
                        let ty = tIdx / tilesX
                        let cellX0 = tx * 8
                        let cellY0 = ty * 8
                        let tileCellsX = min(8, bx - cellX0)
                        let tileCellsY = min(8, by - cellY0)
                        let tileBlocks = tileCellsX * tileCellsY
                        tr.dcFlat.withUnsafeBufferPointer { srcBuf in
                            let src = srcBuf.baseAddress!
                            for ly in 0..<tileCellsY {
                                let dstRow = (cellY0 + ly) * bx + cellX0
                                let srcRow = ly * tileCellsX
                                d0.advanced(by: dstRow).update(from: src.advanced(by: srcRow), count: tileCellsX)
                                d1.advanced(by: dstRow).update(from: src.advanced(by: tileBlocks + srcRow), count: tileCellsX)
                                d2.advanced(by: dstRow).update(from: src.advanced(by: 2 * tileBlocks + srcRow), count: tileCellsX)
                            }
                        }
                    }

                    ac0.withUnsafeMutableBufferPointer { ac0Buf in
                        ac1.withUnsafeMutableBufferPointer { ac1Buf in
                            ac2.withUnsafeMutableBufferPointer { ac2Buf in
                                let a0 = ac0Buf.baseAddress!
                                let a1 = ac1Buf.baseAddress!
                                let a2 = ac2Buf.baseAddress!
                                var currentOffset = 0

                                for byIdx in 0..<by {
                                    let rowOff = byIdx * bx
                                    for bxIdx in 0..<bx {
                                        let bIdx = rowOff + bxIdx
                                        let tIdx = Int(tileIdxForBlock[bIdx])
                                        if tIdx < 0 { continue }
                                        let lIdx = Int(leafIdxForBlock[bIdx])
                                        let tr = tileResults[tIdx]!
                                        let leaf = tr.leaves[lIdx]
                                        let cellsW = Int(leaf.cellsX)
                                        let cellsH = Int(leaf.cellsY)
                                        let count = cellsW * cellsH * 64
                                        let id = Int(leaf.identifier)
                                        strategies.append(Int32(id))
                                        quantisation.append(leaf.quantisation)
                                        transforms.append(
                                            VarDCTStrategyMap.Transform(
                                                identifier: id,
                                                x: Int(leaf.x),
                                                y: Int(leaf.y),
                                                cellsX: cellsW,
                                                cellsY: cellsH,
                                                quantisation: UInt32(leaf.quantisation),
                                                coefficientOffset: currentOffset
                                            )
                                        )
                                        let tx = tIdx % tilesX
                                        let ty = tIdx / tilesX
                                        let tileCellsX = min(8, bx - tx * 8)
                                        let tileCellsY = min(8, by - ty * 8)
                                        let tileACCount = tileCellsX * tileCellsY * 64
                                        let acTileOff = Int(leaf.acTileOffset)
                                        tr.acFlat.withUnsafeBufferPointer { acSrcBuf in
                                            let acSrc = acSrcBuf.baseAddress!
                                            a0.advanced(by: currentOffset).update(from: acSrc.advanced(by: acTileOff), count: count)
                                            a1.advanced(by: currentOffset).update(from: acSrc.advanced(by: tileACCount + acTileOff), count: count)
                                            a2.advanced(by: currentOffset).update(from: acSrc.advanced(by: 2 * tileACCount + acTileOff), count: count)
                                        }
                                        currentOffset += count
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return Result(
            strategies: strategies,
            quantisation: quantisation,
            dc: [dc0, dc1, dc2],
            ac: [ac0, ac1, ac2],
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
