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
        var challenger: [Int32] = []
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
            self.small = consume small; self.large = consume large
            self.pixels = pixels
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
        var largeConstruction: [Int: VarDCTLargeAnalysis] = [:], weightConstruction: [Int: [Float]] = [:], orderConstruction: [Int: [Int]] = [:]
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
            if orderConstruction[orderKey] != nil {
                // Identical normalized shapes use one immutable scan owner,
                // while each original per-strategy admission remains charged.
                try budget.reserveWorkspace(rows * columns * MemoryLayout<Int>.stride)
                try budget.checkpoint()
            } else {
                orderConstruction[orderKey] = try VarDCTOrders.natural(width: max(rows, columns) / 8,
                    height: min(rows, columns) / 8, budget: budget)
            }
        }
        let large = largeConstruction, weights = weightConstruction, orders = orderConstruction
        let dcScale = [4096.0,512,256].map { Double(scale) * 17 * $0 / 65536 }
        @Sendable func quantise(_ value: Double) throws -> Int32 {
            let rounded = value.rounded()
            guard rounded.isFinite, rounded >= Double(Int32.min), rounded <= Double(Int32.max) else {
                throw VarDCTError.nonFiniteSample
            }
            return Int32(rounded)
        }
        var qf = [Int32](repeating: 5, count: cells)
        if adaptiveQuantisation {
            var patch: [Float] = []
            for y in 0..<by { for x in 0..<bx {
                // Keep the original conservative per-cell admission, but reuse
                // a single patch owner rather than allocate three channel arrays
                // and their outer owner before immediately reducing the samples.
                try budget.reserveWorkspace(192 * MemoryLayout<Float>.stride)
                if patch.isEmpty { patch = [Float](repeating: 0, count: 192) }
                try patch.withUnsafeMutableBufferPointer { target in
                    for yy in 0..<8 {
                        try budget.checkpoint()
                        for xx in 0..<8 {
                            let source = min(height - 1, y * 8 + yy) * width + min(width - 1, x * 8 + xx)
                            for c in 0..<3 { target[c * 64 + yy * 8 + xx] = planes[c][source] }
                        }
                    }
                    qf[y * bx + x] = try VarDCTEncoderPreparation.quantisation(
                        UnsafeBufferPointer(target), distance: distance)
                }
            } }
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
                swap(&smallChallenger, &scratch.challenger)
                defer { swap(&smallChallenger, &scratch.challenger) }
                var previousPatch: (x: Int, y: Int, rows: Int, columns: Int)?
                func evaluate(_ id: Int, _ x: Int, _ y: Int, _ q: Int32,
                              values: inout [Int32]) throws -> Int {
                    try budget.checkpoint()
                    let rows = large[id]?.rows ?? 8, columns = large[id]?.columns ?? 8
                    let count = rows * columns, covered = count / 64
                    let orderKey = max(rows, columns) * 64 + min(rows, columns)
                    guard let weight = weights[id], let order = orders[orderKey] else { throw VarDCTError.invalidTransform }
                    if count == 64 && (previousPatch?.x != x || previousPatch?.y != y) {
                        try planes[0].withUnsafeBufferPointer { first in
                            try planes[1].withUnsafeBufferPointer { second in
                                try planes[2].withUnsafeBufferPointer { third in
                                    try scratch.pixels.withUnsafeMutableBufferPointer { target in
                                        for yy in 0..<rows {
                                            try budget.checkpoint()
                                            let sourceRow = min(height - 1, y * 8 + yy) * width
                                            for xx in 0..<columns {
                                                let source = sourceRow + min(width - 1, x * 8 + xx)
                                                let at = yy * columns + xx
                                                target[at] = first[source]
                                                target[64 + at] = second[source]
                                                target[128 + at] = third[source] - second[source]
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        previousPatch = (x, y, rows, columns)
                    }
                    try budget.reserveWorkspace((count + covered) * 3 * MemoryLayout<Int32>.stride)
                    if values.isEmpty { values = [Int32](repeating: 0, count: (count + covered) * 3) }
                    guard values.count == (count + covered) * 3 else { throw VarDCTError.invalidTransform }
                    var cost = 0
                    // Reuse occurs only for 8x8 trials: every DC and non-DC AC
                    // position is overwritten. The omitted AC DC slot starts at
                    // zero and is never written by any of the small strategies.
                    try values.withUnsafeMutableBufferPointer { target in
                        for c in 0..<3 {
                            let base = c * (count + covered)
                            if let plan = large[id] {
                                // Fill only the channel immediately consumed by
                                // this transform. The small-cell cache prefix
                                // survives every large trial unchanged.
                                try planes[c].withUnsafeBufferPointer { channel in
                                    try planes[1].withUnsafeBufferPointer { luminance in
                                        try scratch.pixels.withUnsafeMutableBufferPointer { pixels in
                                            for yy in 0..<rows {
                                                try budget.checkpoint()
                                                let sourceRow = min(height - 1, y * 8 + yy) * width
                                                for xx in 0..<columns {
                                                    let source = sourceRow + min(width - 1, x * 8 + xx)
                                                    pixels[192 + yy * columns + xx] = c == 2
                                                        ? channel[source] - luminance[source] : channel[source]
                                                }
                                            }
                                        }
                                    }
                                }
                                try scratch.pixels.withUnsafeBufferPointer {
                                    try plan.apply(UnsafeBufferPointer(rebasing: $0[192..<(192 + count)]), workspace: &scratch.large)
                                }
                            } else {
                                try scratch.pixels.withUnsafeBufferPointer {
                                    try small.apply(UnsafeBufferPointer(rebasing: $0[(c * 64)..<(c * 64 + 64)]), identifier: id, workspace: &scratch.small)
                                }
                            }
                            for k in 0..<covered {
                                let value = covered > 1 ? scratch.large.dcValue(at: k) : scratch.small.value(at: 0)
                                target[base + k] = try quantise(Double(value) * dcScale[c])
                            }
                            var last = 0, magnitude = 0
                            // Natural scans place all DC frequencies first, including the
                            // non-contiguous low-frequency rectangle of large transforms.
                            for k in covered..<count {
                                let position = order[k]
                                let coefficient = covered > 1 ? scratch.large.coefficient(at: position) : scratch.small.value(at: position)
                                let value = try quantise(Double(coefficient) * Double(weight[c * count + position])
                                    * Double(scale) / 65536 * Double(q))
                                target[base + covered + position] = value
                                if value != 0 { last = k; magnitude += 32 - value.magnitude.leadingZeroBitCount }
                            }
                            cost += 4 + 2 * last + magnitude
                        }
                    }
                    return cost
                }
                func trial(_ id: Int, _ x: Int, _ y: Int, _ q: Int32) throws -> Pick {
                    var values: [Int32] = []
                    let cost = try evaluate(id, x, y, q, values: &values)
                    let rows = large[id]?.rows ?? 8, columns = large[id]?.columns ?? 8
                    return Pick(id: id, x: x, y: y, width: columns / 8, height: rows / 8, q: q, values: values, cost: cost)
                }
                func cell(_ x: Int, _ y: Int, _ q: Int32) throws -> Pick {
                    var best = try trial(0,x,y,q)
                    let initial = best.cost
                    if initial > 54 {
                        for id in [13,12,3,2,1,17,16,15,14] where id < 14 || initial > 120 {
                            let cost = try evaluate(id, x, y, q, values: &smallChallenger)
                            if cost <= best.cost {
                                swap(&best.values, &smallChallenger)
                                best.id = id; best.cost = cost
                            }
                        }
                    }
                    return best
                }
                func region(_ x: Int, _ y: Int, _ size: Int, _ q: Int32) throws -> [Pick] {
                    if size == 1 { return [try cell(x,y,q)] }
                    let half = size / 2
                    var split: [Pick] = []
                    for (dx,dy) in [(0,0),(half,0),(0,half),(half,half)] {
                        split += try region(x+dx,y+dy,half,q)
                    }
                    let square = size == 2 ? 4 : size == 4 ? 5 : 18
                    let vertical = size == 2 ? 6 : size == 4 ? 10 : 19
                    let horizontal = size == 2 ? 7 : size == 4 ? 11 : 20
                    // Retain only the best partition and the current challenger.
                    // Ranking keeps the predecessor's exact tie priorities: 16 favours
                    // square/v/h before split, while larger regions favour split.
                    var best = split, cost = split.reduce(0) { $0 + $1.cost }
                    var rank = size == 2 ? 3 : 0
                    split.removeAll(keepingCapacity: false)
                    func consider(_ candidate: [Pick], rank candidateRank: Int) {
                        let candidateCost = candidate.reduce(0) { $0 + $1.cost }
                        if candidateCost < cost || (candidateCost == cost && candidateRank < rank) {
                            best = candidate; cost = candidateCost; rank = candidateRank
                        }
                    }
                    consider([try trial(square,x,y,q)], rank: size == 2 ? 0 : 1)
                    consider([try trial(vertical,x,y,q), try trial(vertical,x+half,y,q)], rank: size == 2 ? 1 : 2)
                    consider([try trial(horizontal,x,y,q), try trial(horizontal,x,y+half,q)], rank: size == 2 ? 2 : 3)
                    if size == 4 {
                        consider(try (0..<4).map { try trial(8,x+$0,y,q) }, rank: 4)
                        consider(try (0..<4).map { try trial(9,x,y+$0,q) }, rank: 5)
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
