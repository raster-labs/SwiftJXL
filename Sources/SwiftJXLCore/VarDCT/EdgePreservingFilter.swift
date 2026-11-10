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
        for c in 0..<3 {
            try input[c].withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                for i in 0..<samples {
                    if i & 255 == 0 { try budget.checkpoint() }
                    guard base[i].isFinite else { throw VarDCTError.nonFiniteSample }
                }
            }
        }
        guard iterations > 0 else { return input }
        try budget.reserveWorkspace(ScalarOperationBudget.sum(ScalarOperationBudget.product(blocks, 4), 4096))
        var sigma = [Float](repeating: 0, count: blocks)
        let globalScaleNorm = Float(globalScale) / 65536
        for i in 0..<blocks {
            if i & 255 == 0 { try budget.checkpoint() }
            let q = globalScaleNorm * Float(quantisation[i])
            let raw = 0.46 / (q * -1.1715728752538099024) * Float(sharpness[i]) / 7
            sigma[i] = 1 / min(-0.0001, raw)
        }
        func mirror(_ value: Int, size: Int) -> Int {
            let period = size * 2
            let m = (value % period + period) % period
            return m < size ? m : period - 1 - m
        }
        guard width <= Int.max / 2, height <= Int.max / 2 else { throw VarDCTError.invalidTransform }
        var mirrorX = [Int](repeating: 0, count: width + 6)
        for u in -3..<(width + 3) {
            mirrorX[u + 3] = mirror(u, size: width)
        }
        var mirrorY = [Int](repeating: 0, count: height + 6)
        for v in -3..<(height + 3) {
            mirrorY[v + 3] = mirror(v, size: height) * width
        }
        var result = input
        let stages = iterations == 3 ? [0, 1, 2] : (iterations == 2 ? [1, 2] : [1])
        let cardinal: [(Int, Int)] = [(0, -1), (-1, 0), (1, 0), (0, 1)]
        // Offsets are (x,y); order follows libjxl's row-major table.
        let neighbours0: [(Int, Int)] = [(0, -2), (-1, -1), (0, -1), (1, -1), (-2, 0), (-1, 0),
                                         (1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)]
        let threshold: Float = -3.90524291751269967465540850526868
        for stage in stages {
            try budget.reserveWorkspace(ScalarOperationBudget.product(samples, 12))
            let source = result
            var out0 = source[0]
            var out1 = source[1]
            var out2 = source[2]
            let sigmaScale: Float = stage == 0 ? 0.9 * 1.65 : (stage == 2 ? 6.5 * 1.65 : 1.65)
            let sigmaBorderScale: Float = sigmaScale * (2.0 / 3.0)
            let neighbours = stage == 0 ? neighbours0 : cardinal
            try source[0].withUnsafeBufferPointer { s0Buf in
                try source[1].withUnsafeBufferPointer { s1Buf in
                    try source[2].withUnsafeBufferPointer { s2Buf in
                        try out0.withUnsafeMutableBufferPointer { o0Buf in
                            try out1.withUnsafeMutableBufferPointer { o1Buf in
                                try out2.withUnsafeMutableBufferPointer { o2Buf in
                                    try sigma.withUnsafeBufferPointer { sigBuf in
                                        try mirrorX.withUnsafeBufferPointer { mxBuf in
                                            try mirrorY.withUnsafeBufferPointer { myBuf in
                                                try neighbours.withUnsafeBufferPointer { nbBuf in
                                                    let s0 = s0Buf.baseAddress!
                                                    let s1 = s1Buf.baseAddress!
                                                    let s2 = s2Buf.baseAddress!
                                                    let o0 = o0Buf.baseAddress!
                                                    let o1 = o1Buf.baseAddress!
                                                    let o2 = o2Buf.baseAddress!
                                                    let sig = sigBuf.baseAddress!
                                                    let mx = mxBuf.baseAddress! + 3
                                                    let my = myBuf.baseAddress! + 3
                                                    let nb = nbBuf.baseAddress!
                                                    let nbCount = nbBuf.count
                                                    if stage == 2 {
                                                        for y in 0..<height {
                                                            let rowOff = y &* width
                                                            let rowSigma = (y >> 3) &* blocksX
                                                            let yIsBorder = (y & 7) == 0 || (y & 7) == 7
                                                            let ym1 = my[y &- 1]
                                                            let yp1 = my[y &+ 1]
                                                            for x in 0..<width {
                                                                if x & 31 == 0 { try budget.checkpoint() }
                                                                let base = sig[rowSigma &+ (x >> 3)]
                                                                if base < threshold { continue }
                                                                let isBorder = yIsBorder || (x & 7) == 0 || (x & 7) == 7
                                                                let inverse = base * (isBorder ? sigmaBorderScale : sigmaScale)
                                                                let at = rowOff &+ x
                                                                var sum: Float = 1
                                                                let c0 = s0[at], c1 = s1[at], c2 = s2[at]
                                                                var a = c0, b = c1, c = c2
                                                                let t0 = ym1 &+ x
                                                                let t1 = rowOff &+ mx[x &- 1]
                                                                let t2 = rowOff &+ mx[x &+ 1]
                                                                let t3 = yp1 &+ x
                                                                let targets = (t0, t1, t2, t3)
                                                                withUnsafeBytes(of: targets) { raw in
                                                                    let tPtr = raw.bindMemory(to: Int.self).baseAddress!
                                                                    for k in 0..<4 {
                                                                        let to = tPtr[k]
                                                                        let n0 = s0[to], n1 = s1[to], n2 = s2[to]
                                                                        let d0 = abs(c0 - n0)
                                                                        let d1 = abs(c1 - n1)
                                                                        let d2 = abs(c2 - n2)
                                                                        let sad = (d0 * 40 + d1 * 5) + d2 * 3.5
                                                                        let weight = max(0, sad * inverse + 1)
                                                                        sum += weight
                                                                        a += weight * n0
                                                                        b += weight * n1
                                                                        c += weight * n2
                                                                    }
                                                                }
                                                                let inverseSum = 1 / sum
                                                                guard a.isFinite, b.isFinite, c.isFinite, inverseSum.isFinite else {
                                                                    throw VarDCTError.nonFiniteSample
                                                                }
                                                                o0[at] = a * inverseSum
                                                                o1[at] = b * inverseSum
                                                                o2[at] = c * inverseSum
                                                            }
                                                        }
                                                    } else {
                                                        for y in 0..<height {
                                                            let rowOff = y &* width
                                                            let rowSigma = (y >> 3) &* blocksX
                                                            let yIsBorder = (y & 7) == 0 || (y & 7) == 7
                                                            let ym1 = my[y &- 1]
                                                            let yp1 = my[y &+ 1]
                                                            for x in 0..<width {
                                                                if x & 31 == 0 { try budget.checkpoint() }
                                                                let base = sig[rowSigma &+ (x >> 3)]
                                                                if base < threshold { continue }
                                                                let isBorder = yIsBorder || (x & 7) == 0 || (x & 7) == 7
                                                                let inverse = base * (isBorder ? sigmaBorderScale : sigmaScale)
                                                                let at = rowOff &+ x
                                                                let p1 = ym1 &+ x
                                                                let p2 = rowOff &+ mx[x &- 1]
                                                                let p3 = yp1 &+ x
                                                                let p4 = rowOff &+ mx[x &+ 1]
                                                                let c0_0 = s0[at], c0_1 = s0[p1], c0_2 = s0[p2], c0_3 = s0[p3], c0_4 = s0[p4]
                                                                let c1_0 = s1[at], c1_1 = s1[p1], c1_2 = s1[p2], c1_3 = s1[p3], c1_4 = s1[p4]
                                                                let c2_0 = s2[at], c2_1 = s2[p1], c2_2 = s2[p2], c2_3 = s2[p3], c2_4 = s2[p4]
                                                                var sum: Float = 1
                                                                var a = c0_0, b = c1_0, c = c2_0
                                                                for k in 0..<nbCount {
                                                                    let (dx, dy) = nb[k]
                                                                    let nx = x &+ dx
                                                                    let ny = y &+ dy
                                                                    let ry0 = my[ny]
                                                                    let ryM1 = my[ny &- 1]
                                                                    let ryP1 = my[ny &+ 1]
                                                                    let rx0 = mx[nx]
                                                                    let rxM1 = mx[nx &- 1]
                                                                    let rxP1 = mx[nx &+ 1]
                                                                    let q0 = ry0 &+ rx0
                                                                    let q1 = ryM1 &+ rx0
                                                                    let q2 = ry0 &+ rxM1
                                                                    let q3 = ryP1 &+ rx0
                                                                    let q4 = ry0 &+ rxP1
                                                                    let n0_0 = s0[q0], n1_0 = s1[q0], n2_0 = s2[q0]
                                                                    let d0 = (((abs(c0_0 - n0_0) + abs(c0_1 - s0[q1])) + abs(c0_2 - s0[q2])) + abs(c0_3 - s0[q3])) + abs(c0_4 - s0[q4])
                                                                    let d1 = (((abs(c1_0 - n1_0) + abs(c1_1 - s1[q1])) + abs(c1_2 - s1[q2])) + abs(c1_3 - s1[q3])) + abs(c1_4 - s1[q4])
                                                                    let d2 = (((abs(c2_0 - n2_0) + abs(c2_1 - s2[q1])) + abs(c2_2 - s2[q2])) + abs(c2_3 - s2[q3])) + abs(c2_4 - s2[q4])
                                                                    let sad = (d0 * 40 + d1 * 5) + d2 * 3.5
                                                                    let weight = max(0, sad * inverse + 1)
                                                                    sum += weight
                                                                    a += weight * n0_0
                                                                    b += weight * n1_0
                                                                    c += weight * n2_0
                                                                }
                                                                let inverseSum = 1 / sum
                                                                guard a.isFinite, b.isFinite, c.isFinite, inverseSum.isFinite else {
                                                                    throw VarDCTError.nonFiniteSample
                                                                }
                                                                o0[at] = a * inverseSum
                                                                o1[at] = b * inverseSum
                                                                o2[at] = c * inverseSum
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
            }
            result = [out0, out1, out2]
        }
        try budget.checkpoint()
        return result
    }
}
