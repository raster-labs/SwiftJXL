// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Full-frame VarDCT XYB spatial reconstruction and loop filtering per ISO/IEC 18181-1 §§10.1–10.4.
package enum VarDCTReconstruction {
    // ISO/IEC 18181-1 §10.1.4 Table 38 default quantisation bias constants for |q| == 1 and |q| >= 2.
    private static let quantBiasOne: [Float] = [
        1.0 - 0.05465007330715401,
        1.0 - 0.07005449891748593,
        1.0 - 0.049935103337343655,
    ]
    private static let quantBiasNumerator: Float = 0.145

    // ISO/IEC 18181-1 §10.1.3 LLF resampling scale factors for block coverages 1, 2, 4, 8.
    private static let llfScales: [Int: [Double]] = [
        1: [1.0],
        2: [1.0, 1.108937353592731823],
        4: [1.0, 1.025760096781116015, 1.108937353592731823, 1.270559368765487251],
        8: [
            1.0,
            1.0063534990068217,
            1.0257600967811158,
            1.0593017296817173,
            1.1089373535927318,
            1.1777765381970435,
            1.2705593687654873,
            1.3944898413647777,
        ],
    ]

    /// Reconstructs the three `XYB` floating-point planes (`[X, Y, B]`, each of size `width * height`)
    /// from decoded VarDCT coefficients per ISO/IEC 18181-1 §§10.1–10.4.
    package static func xyb(
        _ coefficients: VarDCTCoefficients,
        numericalMode: VarDCTNumericalMode = .scalarNearest
    ) throws -> [[Float]] {
        let budget = coefficients.envelope.budget
        try budget.checkpoint()

        let width = coefficients.width
        let height = coefficients.height
        let blocksX = coefficients.blocksX
        let blocksY = coefficients.blocksY
        let totalBlocks = try ScalarOperationBudget.product(blocksX, blocksY)
        let pixelCount = try ScalarOperationBudget.product(width, height)
        let frame = coefficients.envelope.frame

        let planeWorkspace = try ScalarOperationBudget.product(pixelCount, 3 * MemoryLayout<Float>.size)
        let dcWorkspace = try ScalarOperationBudget.product(totalBlocks, 3 * MemoryLayout<Float>.size)
        try budget.reserveWorkspace(ScalarOperationBudget.sum(planeWorkspace, dcWorkspace))

        // --- 1. Dequantise LLF (DC) and apply LF Chroma-from-Luma (§10.1.1) ---
        let invQuantLF = 65536.0 / (Float(coefficients.globalScale) * Float(coefficients.quantLF))
        let dcExtraMul = 1.0 / Float(1 << coefficients.extraPrecision)
        let dcStep: [Float] = [
            coefficients.lfDequant[0] * invQuantLF * dcExtraMul,
            coefficients.lfDequant[1] * invQuantLF * dcExtraMul,
            coefficients.lfDequant[2] * invQuantLF * dcExtraMul,
        ]
        let lfFactorX = coefficients.baseCorrelationX + Float(coefficients.ytoxLF) / Float(coefficients.colorFactor)
        let lfFactorB = coefficients.baseCorrelationB + Float(coefficients.ytobLF) / Float(coefficients.colorFactor)

        var dcPlanes = [
            [Float](repeating: 0, count: totalBlocks),
            [Float](repeating: 0, count: totalBlocks),
            [Float](repeating: 0, count: totalBlocks),
        ]

        for i in 0..<totalBlocks {
            if (i & 1023) == 0 { try budget.checkpoint() }
            let deqY = Float(coefficients.dc[1][i]) * dcStep[1]
            let deqX = Float(coefficients.dc[0][i]) * dcStep[0] + lfFactorX * deqY
            let deqB = Float(coefficients.dc[2][i]) * dcStep[2] + lfFactorB * deqY
            dcPlanes[0][i] = deqX
            dcPlanes[1][i] = deqY
            dcPlanes[2][i] = deqB
        }

        // --- 2. Optional Adaptive DC Smoothing (§10.1.2) ---
        if (frame.flags & 128) == 0 && blocksX >= 3 && blocksY >= 3 {
            dcPlanes = try applyAdaptiveDCSmoothing(
                dcPlanes,
                blocksX: blocksX,
                blocksY: blocksY,
                dcStep: dcStep,
                budget: budget
            )
        }

        // --- 3. Reconstruct spatial XYB blocks from LLF + dequantised HF (§§10.1.3–10.3) ---
        var planes = [
            [Float](repeating: 0, count: pixelCount),
            [Float](repeating: 0, count: pixelCount),
            [Float](repeating: 0, count: pixelCount),
        ]

        let qmScale: [Float] = [
            Float(pow(0.8, Double(Int(frame.xQmScale) - 2))),
            1.0,
            Float(pow(0.8, Double(Int(frame.bQmScale) - 2))),
        ]
        let invColorFactor = 1.0 / Float(coefficients.colorFactor)
        let tilesX = coefficients.tilesX

        var weightCache = [[Float]?](repeating: nil, count: 27)
        var inverseAxes = ScaledDCT.AxisBank(direction: .inverse, budget: budget)
        var dctPlans: [Int: ScaledDCT] = [:]

        for transform in coefficients.transforms {
            try budget.checkpoint()
            let id = transform.identifier
            let bx = transform.x
            let by = transform.y
            let cx = transform.cellsX
            let cy = transform.cellsY
            let rows = cy * 8
            let columns = cx * 8
            let count = rows * columns
            let normRows = min(rows, columns)
            let normCols = max(rows, columns)
            let llfRows = min(cx, cy)
            let llfCols = max(cx, cy)
            let baseOffset = transform.coefficientOffset

            let weights: [Float]
            if let cached = weightCache[id] {
                weights = cached
            } else {
                let w = try VarDCTQuantWeights.make(
                    identifier: id,
                    rows: rows,
                    columns: columns,
                    budget: budget
                )
                weightCache[id] = w
                weights = w
            }

            let invScale = 65536.0 / (Float(coefficients.globalScale) * Float(transform.quantisation))

            // 3a. Dequantise HF coefficients in canonical (normRows x normCols) layout
            var deq = [
                [Float](repeating: 0, count: count),
                [Float](repeating: 0, count: count),
                [Float](repeating: 0, count: count),
            ]

            for c in [1, 0, 2] {
                let cScale = invScale * qmScale[c]
                let wBase = c * count
                coefficients.ac[c].withUnsafeBufferPointer { acBuf in
                    let acPtr = acBuf.baseAddress! + baseOffset
                    deq[c].withUnsafeMutableBufferPointer { deqBuf in
                        let deqPtr = deqBuf.baseAddress!
                        for ny in 0..<normRows {
                            let rowOff = ny * normCols
                            for nx in 0..<normCols {
                                if nx < llfCols && ny < llfRows { continue }
                                let k = rowOff + nx
                                let q = acPtr[k]
                                if q != 0 {
                                    let biased = adjustQuantBias(q, channel: c, numericalMode: numericalMode)
                                    deqPtr[k] = biased * (cScale / weights[wBase + k])
                                }
                            }
                        }
                    }
                }
            }

            // 3b. Apply HF Chroma-from-Luma per 64x64 tile (or per sub-cell for large blocks)
            for ny in 0..<normRows {
                let rowOff = ny * normCols
                for nx in 0..<normCols {
                    if nx < llfCols && ny < llfRows { continue }
                    let k = rowOff + nx
                    let yCoeff = deq[1][k]
                    if yCoeff == 0 { continue }
                    let tx = (bx + (rows >= columns ? (ny / 8) : (nx / 8))) / 8
                    let ty = (by + (rows >= columns ? (nx / 8) : (ny / 8))) / 8
                    let tileIdx = min(coefficients.tilesY - 1, ty) * tilesX + min(tilesX - 1, tx)
                    let fx = coefficients.baseCorrelationX + Float(coefficients.cflX[tileIdx]) * invColorFactor
                    let fb = coefficients.baseCorrelationB + Float(coefficients.cflB[tileIdx]) * invColorFactor
                    deq[0][k] += fx * yCoeff
                    deq[2][k] += fb * yCoeff
                }
            }

            // 3c. Insert LLF (DC) coefficients and run inverse transform per channel
            for c in 0..<3 {
                let blockPixels: [Float]
                if cx == 1 && cy == 1 {
                    deq[c][0] = dcPlanes[c][by * blocksX + bx]
                    switch id {
                    case 0:
                        var transposed = [Float](repeating: 0, count: 64)
                        for y in 0..<8 {
                            for x in 0..<8 {
                                transposed[y * 8 + x] = deq[c][x * 8 + y]
                            }
                        }
                        let planKey = (8 << 16) | 8
                        let plan: ScaledDCT
                        if let cached = dctPlans[planKey] {
                            plan = cached
                        } else {
                            let created = try ScaledDCT(
                                rows: 8,
                                columns: 8,
                                direction: .inverse,
                                budget: budget,
                                axes: &inverseAxes
                            )
                            dctPlans[planKey] = created
                            plan = created
                        }
                        blockPixels = try plan.apply(transposed)

                    case 1, 2, 3, 12, 13:
                        blockPixels = try VarDCTSmallTransforms.inverse(deq[c], identifier: id, budget: budget)

                    case 14, 15, 16, 17:
                        blockPixels = try VarDCTAFV.inverse(deq[c], kind: id - 14, budget: budget)

                    default:
                        throw VarDCTError.unsupportedStrategy(id)
                    }
                } else {
                    let llfFreq = try reconstructLargeLLF(
                        dcPlane: dcPlanes[c],
                        bx: bx,
                        by: by,
                        blocksX: blocksX,
                        cx: cx,
                        cy: cy,
                        id: id
                    )
                    var spatialFreq = [Float](repeating: 0, count: count)
                    if rows >= columns {
                        for y in 0..<rows {
                            for x in 0..<columns {
                                spatialFreq[y * columns + x] = deq[c][x * rows + y]
                            }
                        }
                    } else {
                        spatialFreq = deq[c]
                    }
                    for v in 0..<cy {
                        for u in 0..<cx {
                            spatialFreq[v * columns + u] = llfFreq[v * cx + u]
                        }
                    }

                    let planKey = (rows << 16) | columns
                    let plan: ScaledDCT
                    if let cached = dctPlans[planKey] {
                        plan = cached
                    } else {
                        let created = try ScaledDCT(
                            rows: rows,
                            columns: columns,
                            direction: .inverse,
                            budget: budget,
                            axes: &inverseAxes
                        )
                        dctPlans[planKey] = created
                        plan = created
                    }
                    blockPixels = try plan.apply(spatialFreq)
                }

                // Copy visible samples into output XYB plane (adding Y back to B)
                let px0 = bx * 8
                let py0 = by * 8
                let visW = min(columns, width - px0)
                let visH = min(rows, height - py0)
                if visW > 0 && visH > 0 {
                    for ry in 0..<visH {
                        let srcRow = ry * columns
                        let dstRow = (py0 + ry) * width + px0
                        for rx in 0..<visW {
                            planes[c][dstRow + rx] = blockPixels[srcRow + rx]
                        }
                    }
                }
            }
        }

        // Note: For 1x1 transforms where HF CfL was applied in canonical space, B has Y added via CfL on AC
        // and lfFactorB on DC (where baseCorrelationB == 1.0 by default!).
        // Wait: What if a frame encoded B - Y directly without CfL? No, in ISO/IEC 18181-1 §10.1.1 & §10.1.4,
        // baseCorrelationB defaults to 1.0, so lfFactorB = 1.0 + ytobLF / colorFactor and
        // fb = 1.0 + cflB / colorFactor ALREADY adds 1.0 * Y to B for both DC and AC!
        //Wait: what about LLF frequencies (u, v) != (0, 0) of large transforms (cx > 1 || cy > 1)?
        // They came from dcPlanes[2], which ALREADY had lfFactorB * deqY added at every cell (bx + dx, by + dy)!

        // --- 4. Loop Filters: Gaborish (§10.4.1) and EPF (§10.4.2) ---
        let lf = frame.loopFilter
        if lf.gab {
            for c in 0..<3 {
                planes[c] = try Gaborish.apply(
                    planes[c],
                    width: width,
                    height: height,
                    stride: width,
                    weight1: Gaborish.defaultWeight1,
                    weight2: Gaborish.defaultWeight2,
                    budget: budget
                )
            }
        }

        if lf.epfIters > 0 {
            planes = try EdgePreservingFilter.apply(
                planes,
                width: width,
                height: height,
                iterations: Int(lf.epfIters),
                quantisation: coefficients.quantField,
                sharpness: coefficients.sharpnessField,
                globalScale: coefficients.globalScale,
                budget: budget
            )
        }

        try budget.checkpoint()
        return planes
    }

    // MARK: - Private Reconstruction Helpers

    @inline(__always)
    private static func adjustQuantBias(
        _ q: Int32,
        channel: Int,
        numericalMode: VarDCTNumericalMode
    ) -> Float {
        switch q {
        case 0:
            return 0.0
        case 1:
            return quantBiasOne[channel]
        case -1:
            return -quantBiasOne[channel]
        default:
            let fq = Float(q)
            if numericalMode == .libjxl012ARMInteger {
                return fq - quantBiasNumerator * VarDCTReferenceNumerics.reciprocalEstimate(q)
            } else {
                return fq - (quantBiasNumerator / fq)
            }
        }
    }

    private static func reconstructLargeLLF(
        dcPlane: [Float],
        bx: Int,
        by: Int,
        blocksX: Int,
        cx: Int,
        cy: Int,
        id: Int
    ) throws -> [Float] {
        guard let sx = llfScales[cx], let sy = llfScales[cy] else {
            throw VarDCTError.unsupportedStrategy(id)
        }
        let invCount = 1.0 / Double(cx * cy)
        let sqrt2 = 2.0.squareRoot()
        var out = [Float](repeating: 0, count: cx * cy)

        for v in 0..<cy {
            let normV = (v == 0) ? 1.0 : sqrt2
            for u in 0..<cx {
                let normU = (u == 0) ? 1.0 : sqrt2
                var sum = 0.0
                for y in 0..<cy {
                    let cosY = cos((Double(y) + 0.5) * Double(v) * .pi / Double(cy))
                    let rowBase = (by + y) * blocksX + bx
                    for x in 0..<cx {
                        let cosX = cos((Double(x) + 0.5) * Double(u) * .pi / Double(cx))
                        sum += Double(dcPlane[rowBase + x]) * cosX * cosY
                    }
                }
                let forwardVal = sum * normU * normV * invCount
                out[v * cx + u] = Float(forwardVal * sx[u] * sy[v])
            }
        }
        return out
    }

    private static func applyAdaptiveDCSmoothing(
        _ dc: [[Float]],
        blocksX: Int,
        blocksY: Int,
        dcStep: [Float],
        budget: ScalarOperationBudget
    ) throws -> [[Float]] {
        var out = dc
        for by in 1..<(blocksY - 1) {
            if (by & 15) == 0 { try budget.checkpoint() }
            let ym1 = (by - 1) * blocksX
            let y0 = by * blocksX
            let yp1 = (by + 1) * blocksX

            for bx in 1..<(blocksX - 1) {
                let idx = y0 + bx
                var approx: (Float, Float, Float) = (0, 0, 0)
                var gap: Float = 0

                for c in 0..<3 {
                    let p = dc[c]
                    let center = p[idx]
                    let side = (p[ym1 + bx] + p[yp1 + bx]) + (p[y0 + bx - 1] + p[y0 + bx + 1])
                    let corner = (p[ym1 + bx - 1] + p[ym1 + bx + 1]) + (p[yp1 + bx - 1] + p[yp1 + bx + 1])
                    let sm = 0.05226273532324128 * center + 0.20345139757231578 * side + 0.0334829185968739 * corner
                    let d = abs(center - sm) / dcStep[c]
                    if d > gap { gap = d }
                    if c == 0 { approx.0 = sm }
                    else if c == 1 { approx.1 = sm }
                    else { approx.2 = sm }
                }

                let factor = max(0.0, min(1.0, 3.0 - 4.0 * gap))
                if factor > 0 {
                    out[0][idx] = dc[0][idx] + (approx.0 - dc[0][idx]) * factor
                    out[1][idx] = dc[1][idx] + (approx.1 - dc[1][idx]) * factor
                    out[2][idx] = dc[2][idx] + (approx.2 - dc[2][idx]) * factor
                }
            }
        }
        return out
    }
}
