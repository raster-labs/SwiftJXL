// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Adaptive Four-direction V (`AFV0..3`) 8x8 corner-basis transforms per ISO/IEC 18181-1 §10.2.6.
package enum VarDCTAFV {
    // Normative 16x16 4x4 corner basis from ISO/IEC 18181-1 Annex C / §10.2.6.
    // Basis 0 is constant 1.0 (norm^2 = 16); Basis 1..15 are orthonormal (norm^2 = 1).
    private static let cornerBasis: [[Double]] = [
        // Basis 0
        [
            1.0, 1.0, 1.0, 1.0,
            1.0, 1.0, 1.0, 1.0,
            1.0, 1.0, 1.0, 1.0,
            1.0, 1.0, 1.0, 1.0
        ],
        // Basis 1
        [
             0.876902938,  0.220651805, -0.101400502, -0.101400502,
             0.220651805, -0.101400502, -0.101400502, -0.101400502,
            -0.101400502, -0.101400502, -0.101400502, -0.101400502,
            -0.101400502, -0.101400502, -0.101400502, -0.101400502
        ],
        // Basis 2
        [
             0.000000000,  0.000000000,  0.406700760,  0.444448173,
             0.000000000,  0.000000000,  0.195743993,  0.292910010,
            -0.406700760, -0.195743993,  0.000000000,  0.113790743,
            -0.444448173, -0.292910010, -0.113790743,  0.000000000
        ],
        // Basis 3
        [
             0.000000000,  0.000000000, -0.212557480,  0.308549702,
             0.000000000,  0.470670223, -0.162120521,  0.000000000,
            -0.212557480, -0.162120521, -0.470670223, -0.146429181,
             0.308549702,  0.000000000, -0.146429181,  0.425114959
        ],
        // Basis 4
        [
             0.000000000, -0.707106769,  0.000000000,  0.000000000,
             0.707106769,  0.000000000,  0.000000000,  0.000000000,
             0.000000000,  0.000000000,  0.000000000,  0.000000000,
             0.000000000,  0.000000000,  0.000000000,  0.000000000
        ],
        // Basis 5
        [
            -0.410537750,  0.623548508, -0.064350717, -0.064350717,
             0.623548508, -0.064350717, -0.064350717, -0.064350717,
            -0.064350717, -0.064350717, -0.064350717, -0.064350717,
            -0.064350717, -0.064350717, -0.064350717, -0.064350717
        ],
        // Basis 6
        [
             0.000000000,  0.000000000, -0.451755673,  0.158545032,
             0.000000000, -0.040385153,  0.007418226,  0.393510342,
            -0.451755673,  0.007418226,  0.110741660,  0.082981631,
             0.158545032,  0.393510342,  0.082981631, -0.451755673
        ],
        // Basis 7
        [
             0.000000000,  0.000000000, -0.304684758,  0.511261642,
             0.000000000,  0.000000000, -0.290480137, -0.065787017,
             0.304684758,  0.290480137,  0.000000000, -0.238897741,
            -0.511261642,  0.065787017,  0.238897741,  0.000000000
        ],
        // Basis 8
        [
             0.000000000,  0.000000000,  0.301792949,  0.257923633,
             0.000000000,  0.162723407,  0.095200226,  0.000000000,
             0.301792949,  0.095200226, -0.162723407, -0.353123844,
             0.257923633,  0.000000000, -0.353123844, -0.603585899
        ],
        // Basis 9
        [
             0.000000000,  0.000000000,  0.408248305,  0.000000000,
             0.000000000,  0.000000000,  0.000000000, -0.408248305,
            -0.408248305,  0.000000000,  0.000000000, -0.408248305,
             0.000000000,  0.408248305,  0.408248305,  0.000000000
        ],
        // Basis 10
        [
             0.000000000,  0.000000000,  0.174786702,  0.081261121,
             0.000000000,  0.000000000, -0.367539793, -0.307882220,
            -0.174786702,  0.367539793,  0.000000000,  0.482668906,
            -0.081261121,  0.307882220, -0.482668906,  0.000000000
        ],
        // Basis 11
        [
             0.000000000,  0.000000000, -0.211056009,  0.185671806,
             0.000000000,  0.000000000,  0.492158592, -0.385250151,
             0.211056009, -0.492158592,  0.000000000,  0.174194127,
            -0.185671806,  0.385250151, -0.174194127,  0.000000000
        ],
        // Basis 12
        [
             0.000000000,  0.000000000, -0.142660841, -0.341644675,
             0.000000000,  0.736749768,  0.246271074, -0.085740194,
            -0.142660841,  0.246271074,  0.148833990, -0.047686804,
            -0.341644675, -0.085740194, -0.047686804, -0.142660841
        ],
        // Basis 13
        [
             0.000000000,  0.000000000, -0.138135403,  0.330228269,
             0.000000000,  0.087551147, -0.079467066, -0.461337477,
            -0.138135403, -0.079467066,  0.497246474,  0.125380591,
             0.330228269, -0.461337477,  0.125380591, -0.138135403
        ],
        // Basis 14
        [
             0.000000000,  0.000000000, -0.174376026,  0.070279069,
             0.000000000, -0.292102665,  0.362381727,  0.000000000,
            -0.174376026,  0.362381727,  0.292102665, -0.432660788,
             0.070279069,  0.000000000, -0.432660788,  0.348752052
        ],
        // Basis 15
        [
             0.000000000,  0.000000000,  0.113549873, -0.074175045,
             0.000000000,  0.194028929, -0.435190499,  0.219186842,
             0.113549873, -0.435190499,  0.555044353, -0.254682779,
            -0.074175045,  0.219186842, -0.254682779,  0.113549873
        ]
    ]

    package static let cornerBasisFlat: [Double] = cornerBasis.flatMap { $0 }

    /// Zero-allocation in-place pointer fast path for 8x8 AFV (`kind in 0..<4`).
    /// `scratch` must have capacity for at least 48 `Double`s, and `floatScratch` for at least 64 `Float`s.
    package static func inverseInto(
        _ coefficients: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        kind: Int,
        scratch: UnsafeMutablePointer<Double>,
        floatScratch: UnsafeMutablePointer<Float>
    ) {
        let flipX = (kind & 1) != 0
        let flipY = (kind & 2) != 0

        let afvHalfDC = Double(coefficients[0]) + Double(coefficients[8])
        let dct4x8DC = Double(coefficients[0]) - Double(coefficients[8])
        let afvDC = afvHalfDC + Double(coefficients[1])
        let dct4x4DC = afvHalfDC - Double(coefficients[1])

        let coeff4x8 = floatScratch
        let pixels4x8 = floatScratch
        for fy in 0..<4 {
            let ky = fy * 2 + 1
            for fx in 0..<8 {
                coeff4x8[fy * 8 + fx] = coefficients[ky * 8 + fx]
            }
        }
        coeff4x8[0] = Float(dct4x8DC)
        ScaledDCT.applyUnchecked(
            rows: 4,
            columns: 8,
            direction: .inverse,
            input: coeff4x8,
            output: pixels4x8,
            scratch: scratch
        )

        let coeff4x4 = floatScratch + 32
        let pixels4x4 = floatScratch + 32
        for fy in 0..<4 {
            for fx in 0..<4 {
                let ky = fx * 2
                let kx = fy * 2 + 1
                coeff4x4[fy * 4 + fx] = coefficients[ky * 8 + kx]
            }
        }
        coeff4x4[0] = Float(dct4x4DC)
        ScaledDCT.applyUnchecked(
            rows: 4,
            columns: 4,
            direction: .inverse,
            input: coeff4x4,
            output: pixels4x4,
            scratch: scratch
        )

        let coeffAFV = scratch + 32
        for sy in 0..<4 {
            for sx in 0..<4 {
                coeffAFV[sy * 4 + sx] = Double(coefficients[(sy * 2) * 8 + (sx * 2)])
            }
        }
        coeffAFV[0] = afvDC

        let pixelsAFV = floatScratch + 48
        cornerBasisFlat.withUnsafeBufferPointer { basisBuf in
            let basis = basisBuf.baseAddress!
            for p in 0..<16 {
                var sum = 0.0
                for k in 0..<16 {
                    sum += coeffAFV[k] * basis[k * 16 + p]
                }
                pixelsAFV[p] = Float(sum)
            }
        }

        let afvRowStart = flipY ? 4 : 0
        let dct4x8RowStart = flipY ? 0 : 4
        let afvColStart = flipX ? 4 : 0
        let dct4x4ColStart = flipX ? 0 : 4

        for sy in 0..<4 {
            let row4x8 = dct4x8RowStart + sy
            for x in 0..<8 {
                output[row4x8 * 8 + x] = pixels4x8[sy * 8 + x]
            }

            let rowAFV = afvRowStart + sy
            let srcAFVY = flipY ? (3 - sy) : sy
            for sx in 0..<4 {
                output[rowAFV * 8 + (dct4x4ColStart + sx)] = pixels4x4[sy * 4 + sx]
                let srcAFVX = flipX ? (3 - sx) : sx
                output[rowAFV * 8 + (afvColStart + sx)] = pixelsAFV[srcAFVY * 4 + srcAFVX]
            }
        }
    }

    @inline(__always)
    package static func forwardBasisUnchecked(
        _ corner: UnsafePointer<Float>,
        into output: UnsafeMutablePointer<Float>
    ) {
        var dcSum = 0.0
        for i in 0..<16 {
            dcSum += Double(corner[i])
        }
        output[0] = Float(dcSum * 0.0625)

        cornerBasisFlat.withUnsafeBufferPointer { basisBuf in
            let basis = basisBuf.baseAddress!
            for k in 1..<16 {
                let bRow = basis + k * 16
                var dot = 0.0
                for i in 0..<16 {
                    dot += Double(corner[i]) * bRow[i]
                }
                output[k] = Float(dot)
            }
        }
    }

    /// Reconstructs an 8x8 pixel block from 64 `AFV` (`kind in 0..<4`) coefficients.
    package static func inverse(
        _ coefficients: [Float],
        kind: Int,
        budget: ScalarOperationBudget
    ) throws -> [Float] {
        try budget.checkpoint()
        guard (0..<4).contains(kind), coefficients.count == 64 else {
            throw VarDCTError.invalidTransform
        }
        try budget.reserveWorkspace(64 * MemoryLayout<Float>.size)
        for v in coefficients {
            guard v.isFinite else {
                throw VarDCTError.invalidTransform
            }
        }

        let flipX = (kind & 1) != 0
        let flipY = (kind & 2) != 0

        let idct4x4 = try ScaledDCT(rows: 4, columns: 4, direction: .inverse, budget: budget)
        let idct4x8 = try ScaledDCT(rows: 4, columns: 8, direction: .inverse, budget: budget)

        let afvHalfDC = Double(coefficients[0]) + Double(coefficients[8])
        let dct4x8DC = Double(coefficients[0]) - Double(coefficients[8])
        let afvDC = afvHalfDC + Double(coefficients[1])
        let dct4x4DC = afvHalfDC - Double(coefficients[1])

        // 1. Odd ky rows -> 4x8 IDCT sub-block
        var coeff4x8 = [Float](repeating: 0, count: 32)
        for fy in 0..<4 {
            let ky = fy * 2 + 1
            for fx in 0..<8 {
                coeff4x8[fy * 8 + fx] = coefficients[ky * 8 + fx]
            }
        }
        coeff4x8[0] = Float(dct4x8DC)
        let pixels4x8 = try idct4x8.apply(coeff4x8)

        // 2. Even ky, odd kx (transposed) -> 4x4 IDCT sub-block
        var coeff4x4 = [Float](repeating: 0, count: 16)
        for fy in 0..<4 {
            for fx in 0..<4 {
                let ky = fx * 2
                let kx = fy * 2 + 1
                coeff4x4[fy * 4 + fx] = coefficients[ky * 8 + kx]
            }
        }
        coeff4x4[0] = Float(dct4x4DC)
        let pixels4x4 = try idct4x4.apply(coeff4x4)

        // 3. Even ky, even kx -> 4x4 AFV corner basis
        var coeffAFV = [Double](repeating: 0, count: 16)
        for sy in 0..<4 {
            for sx in 0..<4 {
                coeffAFV[sy * 4 + sx] = Double(coefficients[(sy * 2) * 8 + (sx * 2)])
            }
        }
        coeffAFV[0] = afvDC

        var pixelsAFV = [Float](repeating: 0, count: 16)
        for p in 0..<16 {
            var sum = 0.0
            for k in 0..<16 {
                sum += coeffAFV[k] * cornerBasis[k][p]
            }
            pixelsAFV[p] = Float(sum)
        }

        // Assemble 8x8 output
        var output = [Float](repeating: 0, count: 64)
        let afvRowStart = flipY ? 4 : 0
        let dct4x8RowStart = flipY ? 0 : 4
        let afvColStart = flipX ? 4 : 0
        let dct4x4ColStart = flipX ? 0 : 4

        for sy in 0..<4 {
            let row4x8 = dct4x8RowStart + sy
            for x in 0..<8 {
                output[row4x8 * 8 + x] = pixels4x8[sy * 8 + x]
            }

            let rowAFV = afvRowStart + sy
            let srcAFVY = flipY ? (3 - sy) : sy
            for sx in 0..<4 {
                output[rowAFV * 8 + (dct4x4ColStart + sx)] = pixels4x4[sy * 4 + sx]
                let srcAFVX = flipX ? (3 - sx) : sx
                output[rowAFV * 8 + (afvColStart + sx)] = pixelsAFV[srcAFVY * 4 + srcAFVX]
            }
        }

        return output
    }

    /// Projects a 4x4 corner block onto the 16 forward AFV basis vectors.
    package static func forwardBasis(
        _ corner: UnsafeBufferPointer<Float>,
        into output: UnsafeMutableBufferPointer<Float>,
        budget: ScalarOperationBudget
    ) throws {
        try budget.checkpoint()
        guard corner.count == 16, output.count == 16 else {
            throw VarDCTError.invalidTransform
        }
        for i in 0..<16 {
            guard corner[i].isFinite else {
                throw VarDCTError.invalidTransform
            }
        }
        var dcSum = 0.0
        for i in 0..<16 {
            dcSum += Double(corner[i])
        }
        output[0] = Float(dcSum * 0.0625)

        for k in 1..<16 {
            let basis = cornerBasis[k]
            var dot = 0.0
            for i in 0..<16 {
                dot += Double(corner[i]) * basis[i]
            }
            output[k] = Float(dot)
        }
    }
}
