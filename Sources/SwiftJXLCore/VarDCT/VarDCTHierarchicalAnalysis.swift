// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Codec/VarDCTEncoder.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e. Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause; see libjxl-LICENSE.txt.
import Foundation
import Synchronization

/// Operation-local hierarchical search. Every candidate within a region uses
/// the same quantisation, including all recursive small-cell alternatives.
/// Coefficients are packed in raster transform order, not raster cell order.
package enum VarDCTHierarchicalAnalysis {
    package struct Result {
        package let transforms: [VarDCTStrategyMap.Transform]
        package let strategies: [Int32], quantisation: [Int32]
        package let dc: [[Int32]], ac: [[Int32]]
    }
    private struct Pick: Sendable {
        var id: Int
        let x: Int, y: Int, width: Int, height: Int, q: Int32
        // One owner per trial avoids six child arrays and two outer arrays.
        // Each channel stores its DC rectangle followed by the full AC plane.
        var values: [Int32], cost: Int
    }
    /// One uniquely owned scratch set per bounded worker, reused across joined
    /// row batches. The checked Sendable owner contains no stored raw pointers.
    private struct WorkerScratch: ~Copyable {
        var small: VarDCTSmallAnalysis.Workspace
        var large: VarDCTLargeAnalysis.Workspace
        var pixels: [Float]
        var challenger: [Int32]
        var largeChallenger: [Int32]
        init(budget: ScalarOperationBudget) throws {
            // Complete every throwing step before initializing noncopyable
            // stored fields; local owners unwind normally on admission failure.
            let small = try VarDCTSmallAnalysis.Workspace(budget: budget)
            let large = try VarDCTLargeAnalysis.Workspace(budget: budget)
            try budget.reserveWorkspace(4096 * 3 * MemoryLayout<Float>.stride)
            // Keep all three small-cell channels cached in a disjoint prefix;
            // large transforms need only one channel at a time. Admission
            // remains the original conservative three-large-channel allowance.
            let pixels = [Float](repeating: 0, count: 192 + 4096)
            let challenger = [Int32](repeating: 0, count: 195)
            let largeChallenger = [Int32](repeating: 0, count: 12480)
            self.small = consume small; self.large = consume large
            self.pixels = pixels
            self.challenger = challenger
            self.largeChallenger = largeChallenger
        }
    }
    private final class WorkerState: Sendable {
        let scratch: Mutex<WorkerScratch>
        init(budget: ScalarOperationBudget) throws {
            scratch = Mutex(try WorkerScratch(budget: budget))
        }
    }
    package static func analyse(_ planes: [[Float]], width: Int, height: Int,
                                scale: UInt32, distance: Float, adaptiveQuantisation: Bool,
                                budget: ScalarOperationBudget) throws -> Result {
        guard width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 4 * 1024 * 1024,
              planes.count == 3, planes.allSatisfy({ $0.count == width * height }),
              scale > 0, scale <= 65535, distance.isFinite, distance > 0 else {
            throw VarDCTError.invalidTransform
        }
        let bx = (width + 7) / 8, by = (height + 7) / 8, cells = bx * by
        try budget.reserveWorkspace(cells * (64 * 24 + 256))
        var axes = ScaledDCT.AxisBank(direction: .forward, budget: budget)
        let small = try VarDCTSmallAnalysis(budget: budget, axes: &axes)
        var largeConstruction = [VarDCTLargeAnalysis?](repeating: nil, count: 21)
        var weightConstruction = [[Float]](repeating: [], count: 21)
        var orderConstruction = [[Int]](repeating: [], count: 21)
        var sharedOrders: [Int: [Int]] = [:]
        let ids = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]
        for id in ids {
            // Larger partitions cannot be selected if either cell axis is
            // shorter than their square search region. Avoid constructing
            // their matrices and tables, especially for tiny input images.
            let regionSize = [18,19,20].contains(id) ? 8 : [5,8,9,10,11].contains(id) ? 4 : [4,6,7].contains(id) ? 2 : 1
            if bx < regionSize || by < regionSize { continue }
            let rows: Int, columns: Int
            if [4,5,6,7,8,9,10,11,18,19,20].contains(id) {
                let plan = try VarDCTLargeAnalysis(identifier: id, budget: budget, axes: &axes)
                largeConstruction[id] = plan; rows = plan.rows; columns = plan.columns
            } else { rows = 8; columns = 8 }
            weightConstruction[id] = try VarDCTQuantWeights.make(identifier: id, rows: rows, columns: columns, budget: budget)
            let orderKey = max(rows, columns) * 64 + min(rows, columns)
            if let existing = sharedOrders[orderKey] {
                // Identical normalized shapes use one immutable scan owner,
                // while each original per-strategy admission remains charged.
                try budget.reserveWorkspace(rows * columns * MemoryLayout<Int>.stride)
                try budget.checkpoint()
                orderConstruction[id] = existing
            } else {
                let created = try VarDCTOrders.natural(width: max(rows, columns) / 8,
                    height: min(rows, columns) / 8, budget: budget)
                sharedOrders[orderKey] = created
                orderConstruction[id] = created
            }
        }
        let large = largeConstruction, weights = weightConstruction, orders = orderConstruction
        let dcScale = [4096.0,512,256].map { Double(scale) * 17 * $0 / 65536 }
        let scaleOver65536 = Double(scale) / 65536.0
        @Sendable @inline(__always) func quantise(_ value: Double) throws -> Int32 {
            let rounded = value.rounded()
            guard rounded >= Double(Int32.min), rounded <= Double(Int32.max) else {
                throw VarDCTError.nonFiniteSample
            }
            return Int32(rounded)
        }
        var qf = [Int32](repeating: 5, count: cells)
        if adaptiveQuantisation {
            try budget.reserveWorkspace(cells * 192 * MemoryLayout<Float>.stride)
            var patch = [Float](repeating: 0, count: 192)
            try planes[0].withUnsafeBufferPointer { p0 in
                try planes[1].withUnsafeBufferPointer { p1 in
                    try planes[2].withUnsafeBufferPointer { p2 in
                        try patch.withUnsafeMutableBufferPointer { target in
                            let f0 = p0.baseAddress!, f1 = p1.baseAddress!, f2 = p2.baseAddress!
                            let tPtr = target.baseAddress!
                            for y in 0..<by {
                                try budget.checkpoint()
                                for x in 0..<bx {
                                    for yy in 0..<8 {
                                        let rowOffset = min(height &- 1, y &* 8 &+ yy) &* width
                                        let dstRow = yy &* 8
                                        for xx in 0..<8 {
                                            let source = rowOffset &+ min(width &- 1, x &* 8 &+ xx)
                                            let at = dstRow &+ xx
                                            tPtr[at] = f0[source]
                                            tPtr[64 &+ at] = f1[source]
                                            tPtr[128 &+ at] = f2[source]
                                        }
                                    }
                                    qf[y &* bx &+ x] = try VarDCTEncoderPreparation.quantisation(
                                        UnsafeBufferPointer(target), distance: distance)
                                }
                            }
                        }
                    }
                }
            }
        }
        let quantisationField = qf
        // Every tile starts on eight-cell boundaries in both axes, so no
        // selected region crosses it. Workers share only immutable owned
        // planes/plans and each admits its own scratch. Original global edges
        // and QF indexing remain in trial(); final packing restores raster order.
        // Two-dimensional tiles also balance short, wide images whose final
        // row band would contain almost no work.
        let tilesX = (bx + 7) / 8, tilesY = (by + 7) / 8
        let tileCount = tilesX * tilesY
        // Three admitted scratch sets bound transient workspace and allocator
        // pressure; a caller's lower worker ceiling still takes precedence.
        let workerCount = min(3, min(budget.maximumWorkers, tileCount))
        // Admit the reference-array owner/capacity and every class/lock before
        // map can allocate them; each scratch constructor admits its arrays.
        try budget.reserveWorkspace(64 + workerCount * (MemoryLayout<WorkerState>.stride + 512))
        let workers = try (0..<workerCount).map { _ in try WorkerState(budget: budget) }
        let search: @Sendable (Int, Int, Int, Int) throws -> [Pick] = { worker, firstTile, endTile, batchWorkers in
            try workers[worker].scratch.withLock { scratch in
                // Only this synchronous exclusive borrow can access the worker's
                // transform/pixel owners. Move the challenger into a separate local
                // owner to avoid overlapping inout access during evaluate().
                var smallChallenger: [Int32] = []
                var largeChallenger: [Int32] = []
                swap(&smallChallenger, &scratch.challenger)
                swap(&largeChallenger, &scratch.largeChallenger)
                defer {
                    swap(&smallChallenger, &scratch.challenger)
                    swap(&largeChallenger, &scratch.largeChallenger)
                }
                var previousPatch: (x: Int, y: Int)?
                func evaluateInto(_ id: Int, _ x: Int, _ y: Int, _ q: Int32,
                                  reuseSubtransforms: Bool,
                                  target: UnsafeMutablePointer<Int32>) throws -> Int {
                    let plan = large[id]
                    let rows = plan?.rows ?? 8, columns = plan?.columns ?? 8
                    let count = rows &* columns, covered = count &>> 6
                    let weight = weights[id], order = orders[id]
                    guard !weight.isEmpty, !order.isEmpty else { throw VarDCTError.invalidTransform }
                    let qDouble = Double(q)
                    if count == 64 && (previousPatch?.x != x || previousPatch?.y != y) {
                        planes[0].withUnsafeBufferPointer { first in
                            planes[1].withUnsafeBufferPointer { second in
                                planes[2].withUnsafeBufferPointer { third in
                                    scratch.pixels.withUnsafeMutableBufferPointer { pixBuf in
                                        let f0 = first.baseAddress!, f1 = second.baseAddress!, f2 = third.baseAddress!
                                        let tPtr = pixBuf.baseAddress!
                                        for yy in 0..<8 {
                                            let sourceRow = min(height &- 1, y &* 8 &+ yy) &* width
                                            let dstRow = yy &* 8
                                            for xx in 0..<8 {
                                                let source = sourceRow &+ min(width &- 1, x &* 8 &+ xx)
                                                let at = dstRow &+ xx
                                                tPtr[at] = f0[source]
                                                let lum = f1[source]
                                                tPtr[64 &+ at] = lum
                                                tPtr[128 &+ at] = f2[source] - lum
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        previousPatch = (x, y)
                    }
                    var cost = 0
                    try weight.withUnsafeBufferPointer { wBuf in
                        try order.withUnsafeBufferPointer { oBuf in
                            let wPtr = wBuf.baseAddress!
                            let ordPtr = oBuf.baseAddress!
                            if let plan {
                                let transpose = rows >= columns
                                let rowMask = rows &- 1
                                let rowShift = rows.trailingZeroBitCount
                                let colShift = columns.trailingZeroBitCount
                                for c in 0..<3 {
                                    let base = c &* (count &+ covered)
                                    planes[c].withUnsafeBufferPointer { channel in
                                        planes[1].withUnsafeBufferPointer { luminance in
                                            scratch.pixels.withUnsafeMutableBufferPointer { pixels in
                                                let chPtr = channel.baseAddress!
                                                let lumPtr = luminance.baseAddress!
                                                let pPtr = pixels.baseAddress! + 192
                                                if c == 2 {
                                                    for yy in 0..<rows {
                                                        let sourceRow = min(height &- 1, y &* 8 &+ yy) &* width
                                                        let dstRow = yy &* columns
                                                        for xx in 0..<columns {
                                                            let source = sourceRow &+ min(width &- 1, x &* 8 &+ xx)
                                                            pPtr[dstRow &+ xx] = chPtr[source] - lumPtr[source]
                                                        }
                                                    }
                                                } else {
                                                    for yy in 0..<rows {
                                                        let sourceRow = min(height &- 1, y &* 8 &+ yy) &* width
                                                        let dstRow = yy &* columns
                                                        for xx in 0..<columns {
                                                            let source = sourceRow &+ min(width &- 1, x &* 8 &+ xx)
                                                            pPtr[dstRow &+ xx] = chPtr[source]
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    try scratch.pixels.withUnsafeBufferPointer {
                                        try plan.apply(UnsafeBufferPointer(rebasing: $0[192..<(192 &+ count)]),
                                                       workspace: &scratch.large)
                                    }
                                    try scratch.large.withRawDCTAndDC { dctBuf, dcBuf in
                                        let dctPtr = dctBuf.baseAddress!
                                        let dcPtr = dcBuf.baseAddress!
                                        let dcS = dcScale[c]
                                        let wChannel = wPtr + (c &* count)
                                        let outAC = target + (base &+ covered)
                                        for k in 0..<covered {
                                            target[base &+ k] = try quantise(Double(dcPtr[k]) * dcS)
                                            outAC[ordPtr[k]] = 0
                                        }
                                        var last = 0, magnitude = 0
                                        if transpose {
                                            for k in covered..<count {
                                                let position = ordPtr[k]
                                                let rawIdx = ((position & rowMask) &<< colShift) | (position &>> rowShift)
                                                let coefficient = dctPtr[rawIdx]
                                                let value = try quantise(Double(coefficient) * Double(wChannel[position])
                                                    * scaleOver65536 * qDouble)
                                                outAC[position] = value
                                                if value != 0 {
                                                    last = k
                                                    magnitude &+= 32 &- value.magnitude.leadingZeroBitCount
                                                }
                                            }
                                        } else {
                                            for k in covered..<count {
                                                let position = ordPtr[k]
                                                let coefficient = dctPtr[position]
                                                let value = try quantise(Double(coefficient) * Double(wChannel[position])
                                                    * scaleOver65536 * qDouble)
                                                outAC[position] = value
                                                if value != 0 {
                                                    last = k
                                                    magnitude &+= 32 &- value.magnitude.leadingZeroBitCount
                                                }
                                            }
                                        }
                                        cost &+= 4 &+ 2 &* last &+ magnitude
                                    }
                                }
                            } else {
                                for c in 0..<3 {
                                    let base = c &* 65
                                    try scratch.pixels.withUnsafeBufferPointer {
                                        try small.apply(UnsafeBufferPointer(rebasing: $0[(c &* 64)..<(c &* 64 &+ 64)]),
                                                        identifier: id, workspace: &scratch.small,
                                                        channelSlot: c, reuseSubtransforms: reuseSubtransforms)
                                    }
                                    try scratch.small.withValues { smBuf in
                                        let smPtr = smBuf.baseAddress!
                                        let wChannel = wPtr + (c &* 64)
                                        let outAC = target + (base &+ 1)
                                        target[base] = try quantise(Double(smPtr[0]) * dcScale[c])
                                        outAC[0] = 0
                                        var last = 0, magnitude = 0
                                        for k in 1..<64 {
                                            let position = ordPtr[k]
                                            let coefficient = smPtr[position]
                                            let value = try quantise(Double(coefficient) * Double(wChannel[position])
                                                * scaleOver65536 * qDouble)
                                            outAC[position] = value
                                            if value != 0 {
                                                last = k
                                                magnitude &+= 32 &- value.magnitude.leadingZeroBitCount
                                            }
                                        }
                                        cost &+= 4 &+ 2 &* last &+ magnitude
                                    }
                                }
                            }
                        }
                    }
                    return cost
                }
                func cell(_ x: Int, _ y: Int, _ q: Int32) throws -> Pick {
                    try budget.checkpoint()
                    var bestValues = [Int32](repeating: 0, count: 195)
                    var bestCost = try bestValues.withUnsafeMutableBufferPointer {
                        try evaluateInto(0, x, y, q, reuseSubtransforms: false, target: $0.baseAddress!)
                    }
                    var bestId = 0
                    let initial = bestCost
                    if initial > 54 {
                        for id in [13,12,3,2,1,17,16,15,14] where id < 14 || initial > 120 {
                            let cost = try smallChallenger.withUnsafeMutableBufferPointer {
                                try evaluateInto(id, x, y, q, reuseSubtransforms: true, target: $0.baseAddress!)
                            }
                            if cost <= bestCost {
                                swap(&bestValues, &smallChallenger)
                                bestId = id; bestCost = cost
                            }
                        }
                    }
                    return Pick(id: bestId, x: x, y: y, width: 1, height: 1, q: q, values: bestValues, cost: bestCost)
                }
                func region(_ x: Int, _ y: Int, _ size: Int, _ q: Int32) throws -> [Pick] {
                    if size == 1 { return [try cell(x,y,q)] }
                    let half = size / 2
                    var split: [Pick] = []
                    split.reserveCapacity(size * size)
                    for (dx,dy) in [(0,0),(half,0),(0,half),(half,half)] {
                        split += try region(x+dx,y+dy,half,q)
                    }
                    try budget.checkpoint()
                    let square = size == 2 ? 4 : size == 4 ? 5 : 18
                    let vertical = size == 2 ? 6 : size == 4 ? 10 : 19
                    let horizontal = size == 2 ? 7 : size == 4 ? 11 : 20
                    // Retain only the best partition and the current challenger.
                    // Ranking keeps the predecessor's exact tie priorities: 16 favours
                    // square/v/h before split, while larger regions favour split.
                    var best = split, cost = split.reduce(0) { $0 + $1.cost }
                    var rank = size == 2 ? 3 : 0
                    split.removeAll(keepingCapacity: false)
                    try largeChallenger.withUnsafeMutableBufferPointer { chalBuf in
                        let chalPtr = chalBuf.baseAddress!
                        let sqLen = (size &* size &* 65) &* 3
                        let sqRank = size == 2 ? 0 : 1
                        let sqCost = try evaluateInto(square, x, y, q, reuseSubtransforms: false, target: chalPtr)
                        if sqCost < cost || (sqCost == cost && sqRank < rank) {
                            best = [Pick(id: square, x: x, y: y, width: size, height: size, q: q,
                                         values: Array(chalBuf[0..<sqLen]), cost: sqCost)]
                            cost = sqCost; rank = sqRank
                        }
                        let halfLen = (half &* size &* 65) &* 3
                        let vRank = size == 2 ? 1 : 2
                        let vc0 = try evaluateInto(vertical, x, y, q, reuseSubtransforms: false, target: chalPtr)
                        let vc1 = try evaluateInto(vertical, x + half, y, q, reuseSubtransforms: false, target: chalPtr + halfLen)
                        let vCost = vc0 + vc1
                        if vCost < cost || (vCost == cost && vRank < rank) {
                            best = [
                                Pick(id: vertical, x: x, y: y, width: half, height: size, q: q,
                                     values: Array(chalBuf[0..<halfLen]), cost: vc0),
                                Pick(id: vertical, x: x + half, y: y, width: half, height: size, q: q,
                                     values: Array(chalBuf[halfLen..<(2 &* halfLen)]), cost: vc1)
                            ]
                            cost = vCost; rank = vRank
                        }
                        let hRank = size == 2 ? 2 : 3
                        let hc0 = try evaluateInto(horizontal, x, y, q, reuseSubtransforms: false, target: chalPtr)
                        let hc1 = try evaluateInto(horizontal, x, y + half, q, reuseSubtransforms: false, target: chalPtr + halfLen)
                        let hCost = hc0 + hc1
                        if hCost < cost || (hCost == cost && hRank < rank) {
                            best = [
                                Pick(id: horizontal, x: x, y: y, width: size, height: half, q: q,
                                     values: Array(chalBuf[0..<halfLen]), cost: hc0),
                                Pick(id: horizontal, x: x, y: y + half, width: size, height: half, q: q,
                                     values: Array(chalBuf[halfLen..<(2 &* halfLen)]), cost: hc1)
                            ]
                            cost = hCost; rank = hRank
                        }
                        if size == 4 {
                            let stripLen: Int = 4 * 65 * 3
                            let c8_0 = try evaluateInto(8, x, y, q, reuseSubtransforms: false, target: chalPtr)
                            let c8_1 = try evaluateInto(8, x + 1, y, q, reuseSubtransforms: false, target: chalPtr + stripLen)
                            let c8_2 = try evaluateInto(8, x + 2, y, q, reuseSubtransforms: false, target: chalPtr + (2 * stripLen))
                            let c8_3 = try evaluateInto(8, x + 3, y, q, reuseSubtransforms: false, target: chalPtr + (3 * stripLen))
                            let cost8 = c8_0 + c8_1 + c8_2 + c8_3
                            if cost8 < cost || (cost8 == cost && 4 < rank) {
                                best = [
                                    Pick(id: 8, x: x, y: y, width: 1, height: 4, q: q, values: Array(chalBuf[0..<stripLen]), cost: c8_0),
                                    Pick(id: 8, x: x + 1, y: y, width: 1, height: 4, q: q, values: Array(chalBuf[stripLen..<(2 * stripLen)]), cost: c8_1),
                                    Pick(id: 8, x: x + 2, y: y, width: 1, height: 4, q: q, values: Array(chalBuf[(2 * stripLen)..<(3 * stripLen)]), cost: c8_2),
                                    Pick(id: 8, x: x + 3, y: y, width: 1, height: 4, q: q, values: Array(chalBuf[(3 * stripLen)..<(4 * stripLen)]), cost: c8_3)
                                ]
                                cost = cost8; rank = 4
                            }
                            let c9_0 = try evaluateInto(9, x, y, q, reuseSubtransforms: false, target: chalPtr)
                            let c9_1 = try evaluateInto(9, x, y + 1, q, reuseSubtransforms: false, target: chalPtr + stripLen)
                            let c9_2 = try evaluateInto(9, x, y + 2, q, reuseSubtransforms: false, target: chalPtr + (2 * stripLen))
                            let c9_3 = try evaluateInto(9, x, y + 3, q, reuseSubtransforms: false, target: chalPtr + (3 * stripLen))
                            let cost9 = c9_0 + c9_1 + c9_2 + c9_3
                            if cost9 < cost || (cost9 == cost && 5 < rank) {
                                best = [
                                    Pick(id: 9, x: x, y: y, width: 4, height: 1, q: q, values: Array(chalBuf[0..<stripLen]), cost: c9_0),
                                    Pick(id: 9, x: x, y: y + 1, width: 4, height: 1, q: q, values: Array(chalBuf[stripLen..<(2 * stripLen)]), cost: c9_1),
                                    Pick(id: 9, x: x, y: y + 2, width: 4, height: 1, q: q, values: Array(chalBuf[(2 * stripLen)..<(3 * stripLen)]), cost: c9_2),
                                    Pick(id: 9, x: x, y: y + 3, width: 4, height: 1, q: q, values: Array(chalBuf[(3 * stripLen)..<(4 * stripLen)]), cost: c9_3)
                                ]
                                cost = cost9; rank = 5
                            }
                        }
                    }
                    return best
                }
                var picks: [Pick] = []
                for tile in stride(from: firstTile + worker, to: endTile, by: batchWorkers) {
                    try budget.checkpoint()
                    let startX = (tile % tilesX) * 8
                    let endX = min(bx, startX + 8)
                    let startY = (tile / tilesX) * 8
                    let endY = min(by, startY + 8)
                    let tileWidth = endX - startX
                    var covered = [Bool](repeating: false, count: tileWidth * (endY - startY))
                    for size in [8,4,2,1] {
                        for y in stride(from: startY, through: endY - size, by: size) {
                            for x in stride(from: startX, through: endX - size, by: size) {
                                if covered[(y - startY) * tileWidth + x - startX] { continue }
                                // Aligned powers of two through eight cells never
                                // cross a 32-cell AC-group boundary.
                                picks += try region(x,y,size,quantisationField[y * bx + x])
                                for yy in y..<(y+size) { for xx in x..<(x+size) { covered[(yy - startY) * tileWidth + xx - startX] = true } }
                            }
                        }
                    }
                }
                return picks
            }
        }
        var transforms: [VarDCTStrategyMap.Transform] = [], strategies: [Int32] = [], quantisation: [Int32] = []
        var dc = (0..<3).map { _ in [Int32](repeating: 0, count: cells) }, ac = [[Int32]](repeating: [], count: 3)
        // Every selected region contributes exactly 64 AC positions per cell.
        // Reserve once rather than retaining intermediate geometric-growth slabs.
        for c in 0..<3 { ac[c].reserveCapacity(cells * 64) }
        // Retain selected owners for complete tile rows only. Narrow images
        // include enough rows to occupy the same bounded worker set; wide
        // images retain one row. Joined batches preserve global raster order.
        let rowsPerBatch = max(1, (workerCount + tilesX - 1) / tilesX)
        for firstRow in stride(from: 0, to: tilesY, by: rowsPerBatch) {
            try budget.checkpoint()
            let firstTile = firstRow * tilesX
            let endTile = min(tilesY, firstRow + rowsPerBatch) * tilesX
            let batchWorkers = min(workerCount, endTile - firstTile)
            var picks: [Pick]
            if batchWorkers == 1 {
                picks = try search(0, firstTile, endTile, 1)
            } else {
                // Each bounded map joins all workers before this batch is
                // packed. Its result slots are admitted by parallelMap.
                var partitions = try ScalarEncodingWork.$current.withValue(
                    .init(budget: budget, writerByteLimit: budget.maximumCompressedBytes)) {
                    try parallelMap(batchWorkers) { worker in
                        try search(worker, firstTile, endTile, batchWorkers)
                    }
                }
                picks = []
                while let partition = partitions.popLast() { picks.append(contentsOf: partition) }
            }
            picks.sort { $0.y == $1.y ? $0.x > $1.x : $0.y > $1.y }
            while let pick = picks.popLast() {
                try budget.checkpoint()
                transforms.append(.init(identifier: pick.id, x: pick.x, y: pick.y,
                    cellsX: pick.width, cellsY: pick.height, quantisation: UInt32(pick.q), coefficientOffset: ac[0].count))
                strategies.append(Int32(pick.id)); quantisation.append(pick.q)
                for c in 0..<3 {
                    let covered = pick.width * pick.height, count = covered * 64
                    let base = c * (covered + count)
                    ac[c].append(contentsOf: pick.values[(base + covered)..<(base + covered + count)])
                    for y in 0..<pick.height { for x in 0..<pick.width {
                        dc[c][(pick.y+y) * bx + pick.x+x] = pick.values[base + y * pick.width+x]
                    } }
                }
            }
        }
        return Result(transforms: transforms, strategies: strategies, quantisation: quantisation, dc: dc, ac: ac)
    }
}
