// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Codec/VarDCTEncoder.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause; see libjxl-LICENSE.txt.
import Foundation

/// Operation-owned forward plans for the predecessor's ten single-cell strategies.
/// Output is the codestream coefficient layout, including the unquantised cell DC.
package struct VarDCTSmallAnalysis: Sendable {
    private let budget: ScalarOperationBudget
    private let square4: ScaledDCT, square8: ScaledDCT, wide: ScaledDCT, tall: ScaledDCT
    package init(budget: ScalarOperationBudget) throws {
        self.budget = budget
        square4 = try ScaledDCT(rows: 4, columns: 4, direction: .forward, budget: budget)
        square8 = try ScaledDCT(rows: 8, columns: 8, direction: .forward, budget: budget)
        wide = try ScaledDCT(rows: 4, columns: 8, direction: .forward, budget: budget)
        tall = try ScaledDCT(rows: 8, columns: 4, direction: .forward, budget: budget)
    }
    package func apply(_ pixels: [Float], identifier: Int) throws -> [Float] {
        try budget.checkpoint()
        guard [0,1,2,3,12,13,14,15,16,17].contains(identifier), pixels.count == 64 else {
            throw VarDCTError.invalidTransform
        }
        guard pixels.allSatisfy(\.isFinite) else { throw VarDCTError.nonFiniteSample }
        try budget.reserveWorkspace(1024 * MemoryLayout<Float>.stride)
        var output = [Float](repeating: 0, count: 64)
        if identifier == 0 {
            let values = try square8.apply(pixels)
            for y in 0..<8 { for x in 0..<8 { output[y * 8 + x] = values[x * 8 + y] } }
        } else if identifier == 2 {
            output = pixels
            for size in [8,4,2] {
                let source = output, half = size / 2
                for y in 0..<half { for x in 0..<half {
                    let a = source[y * 16 + x * 2], b = source[y * 16 + x * 2 + 1]
                    let c = source[(y * 2 + 1) * 8 + x * 2], d = source[(y * 2 + 1) * 8 + x * 2 + 1]
                    output[y * 8 + x] = (a + b + c + d) * 0.25
                    output[y * 8 + x + half] = (a + b - c - d) * 0.25
                    output[(y + half) * 8 + x] = (a - b + c - d) * 0.25
                    output[(y + half) * 8 + x + half] = (a - b - c + d) * 0.25
                } }
            }
        } else if identifier == 1 || identifier == 3 {
            var dc = [Float](repeating: 0, count: 4)
            for y in 0..<2 { for x in 0..<2 {
                try budget.checkpoint()
                if identifier == 1 {
                    let centre = pixels[(y * 4 + 1) * 8 + x * 4 + 1]
                    var sum: Float = 0
                    for yy in 0..<4 { for xx in 0..<4 where xx != 0 || yy != 0 {
                        let at = yy == 1 && xx == 1 ? y * 32 + x * 4 : (y * 4 + yy) * 8 + x * 4 + xx
                        let residual = pixels[at] - centre
                        output[(y + yy * 2) * 8 + x + xx * 2] = residual; sum += residual
                    } }
                    dc[y * 2 + x] = centre + sum / 16
                } else {
                    var patch = [Float](repeating: 0, count: 16)
                    for yy in 0..<4 { for xx in 0..<4 { patch[yy * 4 + xx] = pixels[(y * 4 + yy) * 8 + x * 4 + xx] } }
                    let values = try square4.apply(patch); dc[y * 2 + x] = values[0]
                    for yy in 0..<4 { for xx in 0..<4 where xx != 0 || yy != 0 {
                        output[(y + yy * 2) * 8 + x + xx * 2] = values[xx * 4 + yy]
                    } }
                }
            } }
            output[0] = (dc[0] + dc[1] + dc[2] + dc[3]) * 0.25
            output[1] = (dc[0] + dc[1] - dc[2] - dc[3]) * 0.25
            output[8] = (dc[0] - dc[1] + dc[2] - dc[3]) * 0.25
            output[9] = (dc[0] - dc[1] - dc[2] + dc[3]) * 0.25
        } else if identifier == 12 || identifier == 13 {
            let vertical = identifier == 12, rows = vertical ? 4 : 8, columns = vertical ? 8 : 4
            var dc = [Float](repeating: 0, count: 2)
            for half in 0..<2 {
                var patch = [Float](repeating: 0, count: 32)
                for y in 0..<rows { for x in 0..<columns {
                    patch[y * columns + x] = pixels[(y + (vertical ? half * 4 : 0)) * 8 + x + (vertical ? 0 : half * 4)]
                } }
                let values = try (vertical ? wide : tall).apply(patch); dc[half] = values[0]
                for y in 0..<4 { for x in 0..<8 where x != 0 || y != 0 {
                    output[(half + y * 2) * 8 + x] = values[vertical ? y * 8 + x : x * 4 + y]
                } }
            }
            output[0] = (dc[0] + dc[1]) * 0.5; output[8] = (dc[0] - dc[1]) * 0.5
        } else {
            let kind = identifier - 14, ax = kind & 1, ay = kind / 2
            var corner = [Float](repeating: 0, count: 16), square = corner
            var rectangle = [Float](repeating: 0, count: 32)
            for y in 0..<4 { for x in 0..<8 {
                if x < 4 {
                    let yy = ay == 1 ? 3 - y : y, xx = ax == 1 ? 3 - x : x
                    corner[yy * 4 + xx] = pixels[(y + ay * 4) * 8 + x + ax * 4]
                    square[y * 4 + x] = pixels[(y + ay * 4) * 8 + x + (1 - ax) * 4]
                }
                rectangle[y * 8 + x] = pixels[(y + (1 - ay) * 4) * 8 + x]
            } }
            let afv = try VarDCTAFV.forwardBasis(corner, budget: budget)
            let small = try square4.apply(square), large = try wide.apply(rectangle)
            for y in 0..<4 { for x in 0..<8 {
                if x < 4 && (x != 0 || y != 0) {
                    output[y * 16 + x * 2] = afv[y * 4 + x]
                    output[y * 16 + x * 2 + 1] = small[x * 4 + y]
                }
                if x != 0 || y != 0 { output[(y * 2 + 1) * 8 + x] = large[y * 8 + x] }
            } }
            let dc0 = afv[0] * 0.25, dc1 = small[0], dc2 = large[0]
            output[0] = (dc0 + dc1 + 2 * dc2) * 0.25
            output[1] = (dc0 - dc1) * 0.5
            output[8] = (dc0 + dc1 - 2 * dc2) * 0.25
        }
        guard output.allSatisfy(\.isFinite) else { throw VarDCTError.nonFiniteSample }
        try budget.checkpoint()
        return output
    }
}
