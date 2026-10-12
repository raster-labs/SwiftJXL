// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Codec/VarDCTEncoder.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e. Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause; see libjxl-LICENSE.txt.
import Foundation

/// Operation-local hierarchical search. Every candidate within a region uses
/// the same quantisation, including all recursive small-cell alternatives.
/// Coefficients are packed in raster transform order, not raster cell order.
package enum VarDCTHierarchicalAnalysis {
    package struct Result {
        package let transforms: [VarDCTStrategyMap.Transform]
        package let strategies: [Int32], quantisation: [Int32]
        package let dc: [[Int32]], ac: [[Int32]]
    }
    private struct Pick {
        let id: Int, x: Int, y: Int, width: Int, height: Int, q: Int32
        let dc: [[Int32]], ac: [[Int32]], cost: Int
    }
    package static func analyse(_ planes: [[Float]], width: Int, height: Int,
                                scale: UInt32, distance: Float, adaptiveQuantisation: Bool,
                                budget: ScalarOperationBudget) throws -> Result {
        guard width > 0, height > 0, width <= 2048, height <= 2048,
              planes.count == 3, planes.allSatisfy({ $0.count == width * height }),
              scale > 0, scale <= 65535, distance.isFinite, distance > 0 else {
            throw VarDCTError.invalidTransform
        }
        let bx = (width + 7) / 8, by = (height + 7) / 8, cells = bx * by
        try budget.reserveWorkspace(cells * (64 * 24 + 256))
        let small = try VarDCTSmallAnalysis(budget: budget)
        var large: [Int: VarDCTLargeAnalysis] = [:], weights: [Int: [Float]] = [:], orders: [Int: [Int]] = [:]
        let ids = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]
        for id in ids {
            let rows: Int, columns: Int
            if [4,5,6,7,8,9,10,11,18,19,20].contains(id) {
                let plan = try VarDCTLargeAnalysis(identifier: id, budget: budget)
                large[id] = plan; rows = plan.rows; columns = plan.columns
            } else { rows = 8; columns = 8 }
            weights[id] = try VarDCTQuantWeights.make(identifier: id, rows: rows, columns: columns, budget: budget)
            orders[id] = try VarDCTOrders.natural(width: max(rows,columns) / 8,
                height: min(rows,columns) / 8, budget: budget)
        }
        let dcScale = [4096.0,512,256].map { Double(scale) * 17 * $0 / 65536 }
        func quantise(_ value: Double) throws -> Int32 {
            let rounded = value.rounded()
            guard rounded.isFinite, rounded >= Double(Int32.min), rounded <= Double(Int32.max) else {
                throw VarDCTError.nonFiniteSample
            }
            return Int32(rounded)
        }
        func patch(_ x: Int, _ y: Int, _ w: Int, _ h: Int, subtractB: Bool) throws -> [[Float]] {
            try budget.reserveWorkspace(w * h * 3 * MemoryLayout<Float>.stride)
            var pixels = (0..<3).map { _ in [Float](repeating: 0, count: w * h) }
            for yy in 0..<h {
                try budget.checkpoint()
                for xx in 0..<w {
                    let i = min(height - 1, y * 8 + yy) * width + min(width - 1, x * 8 + xx)
                    for c in 0..<3 { pixels[c][yy * w + xx] = planes[c][i] }
                    if subtractB { pixels[2][yy * w + xx] -= pixels[1][yy * w + xx] }
                }
            }
            return pixels
        }
        var qf = [Int32](repeating: 5, count: cells)
        if adaptiveQuantisation {
            for y in 0..<by { for x in 0..<bx {
                qf[y * bx + x] = try VarDCTEncoderPreparation.quantisation(patch(x,y,8,8,subtractB: false), distance: distance)
            } }
        }
        func trial(_ id: Int, _ x: Int, _ y: Int, _ q: Int32) throws -> Pick {
            try budget.checkpoint()
            let rows = large[id]?.rows ?? 8, columns = large[id]?.columns ?? 8
            let count = rows * columns, covered = count / 64
            guard let weight = weights[id], let order = orders[id] else { throw VarDCTError.invalidTransform }
            let pixels = try patch(x,y,columns,rows,subtractB: true)
            try budget.reserveWorkspace((count + covered) * 3 * MemoryLayout<Int32>.stride)
            var dc: [[Int32]] = [], ac: [[Int32]] = [], cost = 0
            for c in 0..<3 {
                let low: [Float], values: [Float]
                if let plan = large[id] {
                    let result = try plan.apply(pixels[c]); low = result.dc; values = result.coefficients
                } else {
                    values = try small.apply(pixels[c], identifier: id); low = [values[0]]
                }
                dc.append(try low.map { try quantise(Double($0) * dcScale[c]) })
                var quantised = [Int32](repeating: 0, count: count), last = 0, magnitude = 0
                // Natural scans place all DC frequencies first, including the
                // non-contiguous low-frequency rectangle of large transforms.
                for k in covered..<count {
                    let position = order[k]
                    let value = try quantise(Double(values[position]) * Double(weight[c * count + position])
                        * Double(scale) / 65536 * Double(q))
                    quantised[position] = value
                    if value != 0 { last = k; magnitude += 32 - value.magnitude.leadingZeroBitCount }
                }
                cost += 4 + 2 * last + magnitude; ac.append(quantised)
            }
            return Pick(id: id, x: x, y: y, width: columns / 8, height: rows / 8, q: q, dc: dc, ac: ac, cost: cost)
        }
        func cell(_ x: Int, _ y: Int, _ q: Int32) throws -> Pick {
            var best = try trial(0,x,y,q)
            let initial = best.cost
            if initial > 54 {
                for id in [13,12,3,2,1,17,16,15,14] where id < 14 || initial > 120 {
                    let candidate = try trial(id,x,y,q)
                    if candidate.cost <= best.cost { best = candidate }
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
            let full = [try trial(square,x,y,q)]
            let v = [try trial(vertical,x,y,q), try trial(vertical,x+half,y,q)]
            let h = [try trial(horizontal,x,y,q), try trial(horizontal,x,y+half,q)]
            // Match predecessor tie priorities: 16 favours the square; larger
            // regions preserve the recursive split on equal estimated cost.
            var choices = size == 2 ? [full,v,h,split] : [split,full,v,h]
            if size == 4 {
                // The one-by-four rectangles are also normative strategies.
                choices.append(try (0..<4).map { try trial(8,x+$0,y,q) })
                choices.append(try (0..<4).map { try trial(9,x,y+$0,q) })
            }
            var best = choices[0], cost = best.reduce(0) { $0 + $1.cost }
            for candidate in choices.dropFirst() {
                let candidateCost = candidate.reduce(0) { $0 + $1.cost }
                if candidateCost < cost { best = candidate; cost = candidateCost }
            }
            return best
        }
        var covered = [Bool](repeating: false, count: cells), picks: [Pick] = []
        for size in [8,4,2,1] {
            for y in stride(from: 0, through: by - size, by: size) {
                for x in stride(from: 0, through: bx - size, by: size) {
                    if covered[y * bx + x] { continue }
                    // Aligned powers of two through eight cells never cross
                    // a 32-cell AC-group boundary.
                    picks += try region(x,y,size,qf[y * bx + x])
                    for yy in y..<(y+size) { for xx in x..<(x+size) { covered[yy * bx + xx] = true } }
                }
            }
        }
        picks.sort { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        var transforms: [VarDCTStrategyMap.Transform] = [], strategies: [Int32] = [], quantisation: [Int32] = []
        var dc = (0..<3).map { _ in [Int32](repeating: 0, count: cells) }, ac = [[Int32]](repeating: [], count: 3)
        for pick in picks {
            try budget.checkpoint()
            transforms.append(.init(identifier: pick.id, x: pick.x, y: pick.y,
                cellsX: pick.width, cellsY: pick.height, quantisation: UInt32(pick.q), coefficientOffset: ac[0].count))
            strategies.append(Int32(pick.id)); quantisation.append(pick.q)
            for c in 0..<3 {
                ac[c].append(contentsOf: pick.ac[c])
                for y in 0..<pick.height { for x in 0..<pick.width {
                    dc[c][(pick.y+y) * bx + pick.x+x] = pick.dc[c][y * pick.width+x]
                } }
            }
        }
        return Result(transforms: transforms, strategies: strategies, quantisation: quantisation, dc: dc, ac: ac)
    }
}
