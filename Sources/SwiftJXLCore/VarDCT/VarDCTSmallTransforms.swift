// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Sub-8x8 VarDCT inverse transforms (`Hornuss`, `DCT2x2`, `DCT4x4`, `DCT4x8`, `DCT8x4`)
/// per ISO/IEC 18181-1 §10.2.
package enum VarDCTSmallTransforms {
    package static func inverse(
        _ coefficients: [Float],
        identifier: Int,
        budget: ScalarOperationBudget
    ) throws -> [Float] {
        try budget.checkpoint()
        guard coefficients.count == 64 else {
            throw VarDCTError.invalidTransform
        }
        guard [1, 2, 3, 12, 13].contains(identifier) else {
            throw VarDCTError.unsupportedStrategy(identifier)
        }
        try budget.reserveWorkspace(64 * MemoryLayout<Float>.size)
        for v in coefficients {
            guard v.isFinite else {
                throw VarDCTError.invalidTransform
            }
        }

        switch identifier {
        case 1:
            return inverseHornuss(coefficients)
        case 2:
            return inverseDCT2x2(coefficients)
        case 3:
            return try inverseDCT4x4(coefficients, budget: budget)
        case 12:
            return try inverseDCT4x8(coefficients, budget: budget)
        case 13:
            return try inverseDCT8x4(coefficients, budget: budget)
        default:
            throw VarDCTError.unsupportedStrategy(identifier)
        }
    }

    @inline(__always)
    private static func idct2x2(_ m00: Double, _ m01: Double, _ m10: Double, _ m11: Double) -> (Double, Double, Double, Double) {
        let a = m00 + m01
        let b = m00 - m01
        let c = m10 + m11
        let d = m10 - m11
        return (a + c, b + d, a - c, b - d)
    }

    /// Strategy 1 (`IDENTITY` / Hornuss): 2x2 IDCT on 4x4 quadrant DCs + zero-mean 4x4 spatial residuals.
    private static func inverseHornuss(_ input: [Float]) -> [Float] {
        // Transposed 2x2 DC block at top-left (ky in 0..1, kx in 0..1)
        let (dc00, dc01, dc10, dc11) = idct2x2(
            Double(input[0]), Double(input[8]),
            Double(input[1]), Double(input[9])
        )
        let dcs = [dc00, dc01, dc10, dc11]
        var output = [Float](repeating: 0, count: 64)

        for qy in 0..<2 {
            for qx in 0..<2 {
                var sub = [Double](repeating: 0, count: 16)
                for sy in 0..<4 {
                    for sx in 0..<4 {
                        let ky = sy * 2 + qy
                        let kx = sx * 2 + qx
                        sub[sy * 4 + sx] = Double(input[ky * 8 + kx])
                    }
                }
                sub[0] = sub[5] // (sy=1, sx=1) holds the top-left residual
                sub[5] = 0.0
                var sum = 0.0
                for v in sub { sum += v }
                let offset = dcs[qy * 2 + qx] - (sum / 16.0)

                for sy in 0..<4 {
                    let py = qy * 4 + sy
                    for sx in 0..<4 {
                        let px = qx * 4 + sx
                        output[py * 8 + px] = Float(offset + sub[sy * 4 + sx])
                    }
                }
            }
        }
        return output
    }

    /// Strategy 2 (`DCT2`): two-level 2x2 hierarchical DC + sixteen 2x2 IDCT blocks.
    private static func inverseDCT2x2(_ input: [Float]) -> [Float] {
        // Level 0: 2x2 IDCT on transposed top-left 2x2 -> four 4x4 quadrant DCs
        let (q00, q01, q10, q11) = idct2x2(
            Double(input[0]), Double(input[8]),
            Double(input[1]), Double(input[9])
        )
        let quadDCs = [q00, q01, q10, q11]

        // Level 1: four 2x2 IDCTs in top-left 4x4 -> sixteen 2x2 block DCs
        var dc2 = [Double](repeating: 0, count: 16)
        for qy in 0..<2 {
            for qx in 0..<2 {
                let m00 = quadDCs[qy * 2 + qx]
                let m01 = Double(input[(2 + qy) * 8 + qx])
                let m10 = Double(input[qy * 8 + (2 + qx)])
                let m11 = Double(input[(2 + qy) * 8 + (2 + qx)])
                let (b00, b01, b10, b11) = idct2x2(m00, m01, m10, m11)
                let baseY = qy * 2
                let baseX = qx * 2
                dc2[(baseY + 0) * 4 + (baseX + 0)] = b00
                dc2[(baseY + 0) * 4 + (baseX + 1)] = b01
                dc2[(baseY + 1) * 4 + (baseX + 0)] = b10
                dc2[(baseY + 1) * 4 + (baseX + 1)] = b11
            }
        }

        // Level 2: sixteen 2x2 IDCT blocks
        var output = [Float](repeating: 0, count: 64)
        for by in 0..<4 {
            for bx in 0..<4 {
                let m00 = dc2[by * 4 + bx]
                let m01 = Double(input[(4 + by) * 8 + bx])
                let m10 = Double(input[by * 8 + (4 + bx)])
                let m11 = Double(input[(4 + by) * 8 + (4 + bx)])
                let (p00, p01, p10, p11) = idct2x2(m00, m01, m10, m11)
                let py = by * 2
                let px = bx * 2
                output[(py + 0) * 8 + (px + 0)] = Float(p00)
                output[(py + 0) * 8 + (px + 1)] = Float(p01)
                output[(py + 1) * 8 + (px + 0)] = Float(p10)
                output[(py + 1) * 8 + (px + 1)] = Float(p11)
            }
        }
        return output
    }

    /// Strategy 3 (`DCT4`): 2x2 IDCT on 4x4 quadrant DCs + four 4x4 IDCT blocks.
    private static func inverseDCT4x4(_ input: [Float], budget: ScalarOperationBudget) throws -> [Float] {
        let (dc00, dc01, dc10, dc11) = idct2x2(
            Double(input[0]), Double(input[8]),
            Double(input[1]), Double(input[9])
        )
        let dcs = [Float(dc00), Float(dc01), Float(dc10), Float(dc11)]
        let idct4 = try ScaledDCT(rows: 4, columns: 4, direction: .inverse, budget: budget)
        var output = [Float](repeating: 0, count: 64)

        for qy in 0..<2 {
            for qx in 0..<2 {
                var sub = [Float](repeating: 0, count: 16)
                for fy in 0..<4 {
                    for fx in 0..<4 {
                        // Transposed sub-block extraction from interleaved 8x8
                        let ky = fx * 2 + qy
                        let kx = fy * 2 + qx
                        sub[fy * 4 + fx] = input[ky * 8 + kx]
                    }
                }
                sub[0] = dcs[qy * 2 + qx]
                let pixels = try idct4.apply(sub)
                for sy in 0..<4 {
                    let py = qy * 4 + sy
                    for sx in 0..<4 {
                        let px = qx * 4 + sx
                        output[py * 8 + px] = pixels[sy * 4 + sx]
                    }
                }
            }
        }
        return output
    }

    /// Strategy 12 (`DCT4X8`): two 4x8 IDCT blocks stacked vertically.
    private static func inverseDCT4x8(_ input: [Float], budget: ScalarOperationBudget) throws -> [Float] {
        let idct4x8 = try ScaledDCT(rows: 4, columns: 8, direction: .inverse, budget: budget)
        var topCoeff = [Float](repeating: 0, count: 32)
        var bottomCoeff = [Float](repeating: 0, count: 32)

        for fy in 0..<4 {
            let kyTop = fy * 2
            let kyBottom = fy * 2 + 1
            for fx in 0..<8 {
                topCoeff[fy * 8 + fx] = input[kyTop * 8 + fx]
                bottomCoeff[fy * 8 + fx] = input[kyBottom * 8 + fx]
            }
        }
        topCoeff[0] = input[0] + input[8]
        bottomCoeff[0] = input[0] - input[8]

        let topPixels = try idct4x8.apply(topCoeff)
        let bottomPixels = try idct4x8.apply(bottomCoeff)
        return topPixels + bottomPixels
    }

    /// Strategy 13 (`DCT8X4`): two 8x4 IDCT blocks side by side horizontally.
    private static func inverseDCT8x4(_ input: [Float], budget: ScalarOperationBudget) throws -> [Float] {
        let idct8x4 = try ScaledDCT(rows: 8, columns: 4, direction: .inverse, budget: budget)
        var leftCoeff = [Float](repeating: 0, count: 32)
        var rightCoeff = [Float](repeating: 0, count: 32)

        for fy in 0..<8 {
            for fx in 0..<4 {
                // Transposed input: c[fy, 2*fx + q] = input[(2*fx + q)*8 + fy]
                leftCoeff[fy * 4 + fx] = input[(fx * 2) * 8 + fy]
                rightCoeff[fy * 4 + fx] = input[(fx * 2 + 1) * 8 + fy]
            }
        }
        leftCoeff[0] = input[0] + input[8]
        rightCoeff[0] = input[0] - input[8]

        let leftPixels = try idct8x4.apply(leftCoeff)
        let rightPixels = try idct8x4.apply(rightCoeff)

        var output = [Float](repeating: 0, count: 64)
        for y in 0..<8 {
            for x in 0..<4 {
                output[y * 8 + x] = leftPixels[y * 4 + x]
                output[y * 8 + (4 + x)] = rightPixels[y * 4 + x]
            }
        }
        return output
    }
}
