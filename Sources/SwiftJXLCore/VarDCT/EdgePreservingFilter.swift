// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift VarDCT/EPF.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e and libjxl stage_epf.cc at
// a7a9c787341cf703dede03c2009fa460cae5e5df. Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause; see libjxl-LICENSE.txt.
import Foundation

/// Default-parameter EPF, operating on visible tight XYB planes. Borders mirror
/// at the visible boundary, including tiny images and multi-pixel filter radii.
package enum EdgePreservingFilter {
    package static func apply(_ input: [[Float]], width: Int, height: Int,
                              iterations: Int, quantisation: [UInt32], sharpness: [Int32],
                              globalScale: UInt32, budget: ScalarOperationBudget) throws -> [[Float]] {
        try budget.checkpoint()
        guard width > 0, height > 0, (0...3).contains(iterations), globalScale > 0 else {
            throw VarDCTError.invalidTransform
        }
        let samples = try ScalarOperationBudget.product(width, height)
        let blocksX = (width - 1) / 8 + 1, blocksY = (height - 1) / 8 + 1
        let blocks = try ScalarOperationBudget.product(blocksX, blocksY)
        guard input.count == 3, input.allSatisfy({ $0.count == samples }),
              quantisation.count == blocks, sharpness.count == blocks,
              quantisation.allSatisfy({ (1...256).contains($0) }),
              sharpness.allSatisfy({ (0...7).contains($0) }) else { throw VarDCTError.invalidTransform }
        // Bounded validation checkpoints; no long input scan ahead of cancellation.
        for c in 0..<3 { for i in 0..<samples {
            if i & 255 == 0 { try budget.checkpoint() }
            guard input[c][i].isFinite else { throw VarDCTError.nonFiniteSample }
        } }
        guard iterations > 0 else { return input }
        try budget.reserveWorkspace(ScalarOperationBudget.sum(ScalarOperationBudget.product(blocks, 4), 4096))
        var sigma = [Float](repeating: 0, count: blocks)
        for i in 0..<blocks {
            if i & 255 == 0 { try budget.checkpoint() }
            let q = Float(globalScale) / 65536 * Float(quantisation[i])
            let raw = 0.46 / (q * -1.1715728752538099024) * Float(sharpness[i]) / 7
            sigma[i] = 1 / min(-0.0001, raw)
        }
        var result = input
        let stages = iterations == 3 ? [0, 1, 2] : (iterations == 2 ? [1, 2] : [1])
        let cardinal = [(0, -1), (-1, 0), (1, 0), (0, 1)]
        // Offsets are (x,y); order follows libjxl's row-major table.
        let neighbours0 = [(0, -2), (-1, -1), (0, -1), (1, -1), (-2, 0), (-1, 0),
                           (1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)]
        let plus = [(0, 0), (0, -1), (-1, 0), (0, 1), (1, 0)]
        let scales: [Float] = [40, 5, 3.5]
        func mirror(_ value: Int, size: Int) -> Int {
            // size<=16384 at the frame boundary. Checked product here also
            // permits this kernel to be called directly with valid storage.
            let period = size * 2
            let m = (value % period + period) % period
            return m < size ? m : period - 1 - m
        }
        guard width <= Int.max / 2, height <= Int.max / 2 else { throw VarDCTError.invalidTransform }
        for stage in stages {
            try budget.reserveWorkspace(ScalarOperationBudget.product(samples, 12))
            let source = result
            var output = source
            let neighbours = stage == 0 ? neighbours0 : cardinal
            let sigmaScale: Float = stage == 0 ? 0.9 * 1.65 : (stage == 2 ? 6.5 * 1.65 : 1.65)
            func index(_ x: Int, _ y: Int) -> Int { mirror(y, size: height) * width + mirror(x, size: width) }
            for y in 0..<height { for x in 0..<width {
                if x & 31 == 0 { try budget.checkpoint() }
                let at = y * width + x, base = sigma[(y / 8) * blocksX + x / 8]
                if base < -3.90524291751269967465540850526868 { continue }
                let border: Float = x % 8 == 0 || x % 8 == 7 || y % 8 == 0 || y % 8 == 7 ? 2 / 3 : 1
                let inverse = base * (sigmaScale * border)
                var sum: Float = 1, a = source[0][at], b = source[1][at], c = source[2][at]
                for (dx, dy) in neighbours {
                    let to = index(x + dx, y + dy)
                    var sad: Float = 0
                    for channel in 0..<3 {
                        var difference: Float = 0
                        if stage == 2 { difference = abs(source[channel][at] - source[channel][to]) }
                        else {
                            for (px, py) in plus {
                                difference += abs(source[channel][index(x + px, y + py)] - source[channel][index(x + dx + px, y + dy + py)])
                            }
                        }
                        sad += difference * scales[channel]
                    }
                    let weight = max(0, sad * inverse + 1)
                    sum += weight
                    a += weight * source[0][to]; b += weight * source[1][to]; c += weight * source[2][to]
                }
                let inverseSum = 1 / sum
                guard a.isFinite, b.isFinite, c.isFinite, inverseSum.isFinite else { throw VarDCTError.nonFiniteSample }
                output[0][at] = a * inverseSum; output[1][at] = b * inverseSum; output[2][at] = c * inverseSum
            } }
            result = output
        }
        try budget.checkpoint()
        return result
    }
}
