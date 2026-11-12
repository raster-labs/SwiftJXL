// SPDX-License-Identifier: MIT
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
    private static func makeImmortalDoublePointer(_ array: [Double]) -> UnsafePointer<Double> {
        let ptr = UnsafeMutablePointer<Double>.allocate(capacity: array.count)
        array.withUnsafeBufferPointer { buf in
            ptr.initialize(from: buf.baseAddress!, count: buf.count)
        }
        return UnsafePointer(ptr)
    }

    private static func makeLLFCosArray(_ n: Int) -> [Double] {
        var mat = [Double](repeating: 0, count: n * n)
        for freq in 0..<n {
            for pos in 0..<n {
                mat[freq * n + pos] = cos((Double(pos) + 0.5) * Double(freq) * .pi / Double(n))
            }
        }
        return mat
    }

    nonisolated(unsafe) private static let llfScalePtr1 = makeImmortalDoublePointer([1.0])
    nonisolated(unsafe) private static let llfScalePtr2 = makeImmortalDoublePointer([1.0, 1.108937353592731823])
    nonisolated(unsafe) private static let llfScalePtr4 = makeImmortalDoublePointer([
        1.0, 1.025760096781116015, 1.108937353592731823, 1.270559368765487251,
    ])
    nonisolated(unsafe) private static let llfScalePtr8 = makeImmortalDoublePointer([
        1.0,
        1.0063534990068217,
        1.0257600967811158,
        1.0593017296817173,
        1.1089373535927318,
        1.1777765381970435,
        1.2705593687654873,
        1.3944898413647777,
    ])

    nonisolated(unsafe) private static let llfCosPtr1 = makeImmortalDoublePointer(makeLLFCosArray(1))
    nonisolated(unsafe) private static let llfCosPtr2 = makeImmortalDoublePointer(makeLLFCosArray(2))
    nonisolated(unsafe) private static let llfCosPtr4 = makeImmortalDoublePointer(makeLLFCosArray(4))
    nonisolated(unsafe) private static let llfCosPtr8 = makeImmortalDoublePointer(makeLLFCosArray(8))

    @inline(__always)
    private static func llfScaleAndCosPointers(_ n: Int) -> (UnsafePointer<Double>, UnsafePointer<Double>)? {
        switch n {
        case 1: return (llfScalePtr1, llfCosPtr1)
        case 2: return (llfScalePtr2, llfCosPtr2)
        case 4: return (llfScalePtr4, llfCosPtr4)
        case 8: return (llfScalePtr8, llfCosPtr8)
        default: return nil
        }
    }

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
        var plane0 = [Float](repeating: 0, count: pixelCount)
        var plane1 = [Float](repeating: 0, count: pixelCount)
        var plane2 = [Float](repeating: 0, count: pixelCount)

        let qmScale: (Float, Float, Float) = (
            Float(pow(0.8, Double(Int(frame.xQmScale) - 2))),
            1.0,
            Float(pow(0.8, Double(Int(frame.bQmScale) - 2)))
        )
        let invColorFactor = 1.0 / Float(coefficients.colorFactor)
        let tilesX = coefficients.tilesX

        var weightCache = [[Float]?](repeating: nil, count: 27)
        let maxCount = max(64, coefficients.transforms.map { $0.coveredCells * 64 }.max() ?? 64)
        var deq0 = [Float](repeating: 0, count: maxCount)
        var deq1 = [Float](repeating: 0, count: maxCount)
        var deq2 = [Float](repeating: 0, count: maxCount)
        var blockPixels = [Float](repeating: 0, count: maxCount)
        var dctScratch = [Double](repeating: 0, count: max(64, maxCount))
        var floatScratch = [Float](repeating: 0, count: 64)
        let dcPlane0 = dcPlanes[0]
        let dcPlane1 = dcPlanes[1]
        let dcPlane2 = dcPlanes[2]

        try plane0.withUnsafeMutableBufferPointer { pl0Buf in
            try plane1.withUnsafeMutableBufferPointer { pl1Buf in
                try plane2.withUnsafeMutableBufferPointer { pl2Buf in
                    try coefficients.ac[0].withUnsafeBufferPointer { ac0Buf in
                        try coefficients.ac[1].withUnsafeBufferPointer { ac1Buf in
                            try coefficients.ac[2].withUnsafeBufferPointer { ac2Buf in
                                try deq0.withUnsafeMutableBufferPointer { deq0Buf in
                                    try deq1.withUnsafeMutableBufferPointer { deq1Buf in
                                        try deq2.withUnsafeMutableBufferPointer { deq2Buf in
                                            try blockPixels.withUnsafeMutableBufferPointer { pixBuf in
                                                try dctScratch.withUnsafeMutableBufferPointer { scratchBuf in
                                                    try floatScratch.withUnsafeMutableBufferPointer { fScratchBuf in
                                                        let pPlane0 = pl0Buf.baseAddress!
                                                        let pPlane1 = pl1Buf.baseAddress!
                                                        let pPlane2 = pl2Buf.baseAddress!
                                                        let ac0Base = ac0Buf.baseAddress
                                                        let ac1Base = ac1Buf.baseAddress
                                                        let ac2Base = ac2Buf.baseAddress
                                                        let pDeq0 = deq0Buf.baseAddress!
                                                        let pDeq1 = deq1Buf.baseAddress!
                                                        let pDeq2 = deq2Buf.baseAddress!
                                                        let pPixels = pixBuf.baseAddress!
                                                        let pScratch = scratchBuf.baseAddress!
                                                        let pFScratch = fScratchBuf.baseAddress!
                                                        let pDeq = (pDeq0, pDeq1, pDeq2)
                                                        let pPlanes = (pPlane0, pPlane1, pPlane2)

                                                        for (tIdx, transform) in coefficients.transforms.enumerated() {
                                                                    if (tIdx & 63) == 0 { try budget.checkpoint() }
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

                                                                    // 3a & 3b. Dequantise HF coefficients and apply HF Chroma-from-Luma
                                                                    if cx == 1 && cy == 1 {
                                                                        let tx = min(tilesX - 1, bx >> 3)
                                                                        let ty = min(coefficients.tilesY - 1, by >> 3)
                                                                        let tileIdx = ty * tilesX + tx
                                                                        let fx = coefficients.baseCorrelationX + Float(coefficients.cflX[tileIdx]) * invColorFactor
                                                                        let fb = coefficients.baseCorrelationB + Float(coefficients.cflB[tileIdx]) * invColorFactor
                                                                        let cScale0 = invScale * qmScale.0
                                                                        let cScale1 = invScale * qmScale.1
                                                                        let cScale2 = invScale * qmScale.2

                                                                        weights.withUnsafeBufferPointer { wBuf in
                                                                            let wPtr = wBuf.baseAddress!
                                                                            let ac0 = ac0Base! + baseOffset
                                                                            let ac1 = ac1Base! + baseOffset
                                                                            let ac2 = ac2Base! + baseOffset
                                                                            if id == 0 {
                                                                                for k in 1..<64 {
                                                                                    let to = (k & 7) * 8 + (k >> 3)
                                                                                    let q1 = ac1[k]
                                                                                    let q0 = ac0[k]
                                                                                    let q2 = ac2[k]
                                                                                    if (q1 | q0 | q2) == 0 {
                                                                                        pDeq1[to] = 0
                                                                                        pDeq0[to] = 0
                                                                                        pDeq2[to] = 0
                                                                                        continue
                                                                                    }
                                                                                    let yCoeff: Float
                                                                                    if q1 != 0 {
                                                                                        yCoeff = adjustQuantBias(q1, channel: 1, numericalMode: numericalMode) * (cScale1 / wPtr[64 + k])
                                                                                    } else {
                                                                                        yCoeff = 0
                                                                                    }
                                                                                    pDeq1[to] = yCoeff

                                                                                    var xCoeff: Float = 0
                                                                                    if q0 != 0 {
                                                                                        xCoeff = adjustQuantBias(q0, channel: 0, numericalMode: numericalMode) * (cScale0 / wPtr[k])
                                                                                    }
                                                                                    if yCoeff != 0 {
                                                                                        xCoeff += fx * yCoeff
                                                                                    }
                                                                                    pDeq0[to] = xCoeff

                                                                                    var bCoeff: Float = 0
                                                                                    if q2 != 0 {
                                                                                        bCoeff = adjustQuantBias(q2, channel: 2, numericalMode: numericalMode) * (cScale2 / wPtr[128 + k])
                                                                                    }
                                                                                    if yCoeff != 0 {
                                                                                        bCoeff += fb * yCoeff
                                                                                    }
                                                                                    pDeq2[to] = bCoeff
                                                                                }
                                                                            } else {
                                                                                for k in 1..<64 {
                                                                                    let q1 = ac1[k]
                                                                                    let q0 = ac0[k]
                                                                                    let q2 = ac2[k]
                                                                                    if (q1 | q0 | q2) == 0 {
                                                                                        pDeq1[k] = 0
                                                                                        pDeq0[k] = 0
                                                                                        pDeq2[k] = 0
                                                                                        continue
                                                                                    }
                                                                                    let yCoeff: Float
                                                                                    if q1 != 0 {
                                                                                        yCoeff = adjustQuantBias(q1, channel: 1, numericalMode: numericalMode) * (cScale1 / wPtr[64 + k])
                                                                                    } else {
                                                                                        yCoeff = 0
                                                                                    }
                                                                                    pDeq1[k] = yCoeff

                                                                                    var xCoeff: Float = 0
                                                                                    if q0 != 0 {
                                                                                        xCoeff = adjustQuantBias(q0, channel: 0, numericalMode: numericalMode) * (cScale0 / wPtr[k])
                                                                                    }
                                                                                    if yCoeff != 0 {
                                                                                        xCoeff += fx * yCoeff
                                                                                    }
                                                                                    pDeq0[k] = xCoeff

                                                                                    var bCoeff: Float = 0
                                                                                    if q2 != 0 {
                                                                                        bCoeff = adjustQuantBias(q2, channel: 2, numericalMode: numericalMode) * (cScale2 / wPtr[128 + k])
                                                                                    }
                                                                                    if yCoeff != 0 {
                                                                                        bCoeff += fb * yCoeff
                                                                                    }
                                                                                    pDeq2[k] = bCoeff
                                                                                }
                                                                            }
                                                                        }
                                                                    } else {
                                                                        let transpose = rows >= columns
                                                                        let cScale0 = invScale * qmScale.0
                                                                        let cScale1 = invScale * qmScale.1
                                                                        let cScale2 = invScale * qmScale.2
                                                                        let wBase1 = count
                                                                        let wBase2 = count * 2
                                                                        let maxTileX = tilesX - 1
                                                                        let maxTileY = coefficients.tilesY - 1
                                                                        let baseCorrX = coefficients.baseCorrelationX
                                                                        let baseCorrB = coefficients.baseCorrelationB

                                                                        weights.withUnsafeBufferPointer { wBuf in
                                                                            coefficients.cflX.withUnsafeBufferPointer { cflXBuf in
                                                                                coefficients.cflB.withUnsafeBufferPointer { cflBBuf in
                                                                                    let wPtr = wBuf.baseAddress!
                                                                                    let cflXPtr = cflXBuf.baseAddress!
                                                                                    let cflBPtr = cflBBuf.baseAddress!
                                                                                    let ac0 = ac0Base! + baseOffset
                                                                                    let ac1 = ac1Base! + baseOffset
                                                                                    let ac2 = ac2Base! + baseOffset

                                                                                    for ny in 0..<normRows {
                                                                                        let rowOff = ny * normCols
                                                                                        let nyBlock = ny >> 3
                                                                                        var nxBase = 0
                                                                                        while nxBase < normCols {
                                                                                            let nxBlock = nxBase >> 3
                                                                                            let tx = min(maxTileX, (bx + (transpose ? nyBlock : nxBlock)) >> 3)
                                                                                            let ty = min(maxTileY, (by + (transpose ? nxBlock : nyBlock)) >> 3)
                                                                                            let tileIdx = ty * tilesX + tx
                                                                                            let fx = baseCorrX + Float(cflXPtr[tileIdx]) * invColorFactor
                                                                                            let fb = baseCorrB + Float(cflBPtr[tileIdx]) * invColorFactor

                                                                                            for nx in nxBase..<(nxBase + 8) {
                                                                                                if nx < llfCols && ny < llfRows { continue }
                                                                                                let k = rowOff + nx
                                                                                                let to = transpose ? (nx * columns + ny) : k
                                                                                                let q1 = ac1[k]
                                                                                                let q0 = ac0[k]
                                                                                                let q2 = ac2[k]
                                                                                                if (q1 | q0 | q2) == 0 {
                                                                                                    pDeq1[to] = 0
                                                                                                    pDeq0[to] = 0
                                                                                                    pDeq2[to] = 0
                                                                                                    continue
                                                                                                }
                                                                                                let yCoeff: Float
                                                                                                if q1 != 0 {
                                                                                                    yCoeff = adjustQuantBias(q1, channel: 1, numericalMode: numericalMode) * (cScale1 / wPtr[wBase1 + k])
                                                                                                } else {
                                                                                                    yCoeff = 0
                                                                                                }
                                                                                                pDeq1[to] = yCoeff

                                                                                                var xCoeff: Float = 0
                                                                                                if q0 != 0 {
                                                                                                    xCoeff = adjustQuantBias(q0, channel: 0, numericalMode: numericalMode) * (cScale0 / wPtr[k])
                                                                                                }
                                                                                                if yCoeff != 0 {
                                                                                                    xCoeff += fx * yCoeff
                                                                                                }
                                                                                                pDeq0[to] = xCoeff

                                                                                                var bCoeff: Float = 0
                                                                                                if q2 != 0 {
                                                                                                    bCoeff = adjustQuantBias(q2, channel: 2, numericalMode: numericalMode) * (cScale2 / wPtr[wBase2 + k])
                                                                                                }
                                                                                                if yCoeff != 0 {
                                                                                                    bCoeff += fb * yCoeff
                                                                                                }
                                                                                                pDeq2[to] = bCoeff
                                                                                            }
                                                                                            nxBase += 8
                                                                                        }
                                                                                    }
                                                                                }
                                                                            }
                                                                        }
                                                                    }

                                                                    // 3c. Insert LLF (DC) coefficients and run inverse transform per channel
                                                                    let px0 = bx * 8
                                                                    let py0 = by * 8
                                                                    let visW = min(columns, width - px0)
                                                                    let visH = min(rows, height - py0)

                                                                    let dcBlockIdx = by * blocksX + bx
                                                                    for c in 0..<3 {
                                                                        let deqPtr = (c == 0) ? pDeq.0 : ((c == 1) ? pDeq.1 : pDeq.2)
                                                                        let dstBase = (c == 0) ? pPlanes.0 : ((c == 1) ? pPlanes.1 : pPlanes.2)
                                                                        if cx == 1 && cy == 1 {
                                                                            deqPtr[0] = (c == 0) ? dcPlane0[dcBlockIdx] : ((c == 1) ? dcPlane1[dcBlockIdx] : dcPlane2[dcBlockIdx])
                                                                            switch id {
                                                                            case 0:
                                                                                ScaledDCT.applyUnchecked(
                                                                                    rows: 8,
                                                                                    columns: 8,
                                                                                    direction: .inverse,
                                                                                    input: deqPtr,
                                                                                    output: pPixels,
                                                                                    scratch: pScratch
                                                                                )

                                                                            case 1, 2, 3, 12, 13:
                                                                                VarDCTSmallTransforms.inverseInto(
                                                                                    deqPtr,
                                                                                    output: pPixels,
                                                                                    identifier: id,
                                                                                    scratch: pScratch,
                                                                                    floatScratch: pFScratch
                                                                                )

                                                                            case 14, 15, 16, 17:
                                                                                VarDCTAFV.inverseInto(
                                                                                    deqPtr,
                                                                                    output: pPixels,
                                                                                    kind: id - 14,
                                                                                    scratch: pScratch,
                                                                                    floatScratch: pFScratch
                                                                                )

                                                                            default:
                                                                                throw VarDCTError.unsupportedStrategy(id)
                                                                            }
                                                                        } else {
                                                                            try reconstructLargeLLFInto(
                                                                                dcPlane: (c == 0) ? dcPlane0 : ((c == 1) ? dcPlane1 : dcPlane2),
                                                                                bx: bx,
                                                                                by: by,
                                                                                blocksX: blocksX,
                                                                                cx: cx,
                                                                                cy: cy,
                                                                                id: id,
                                                                                output: deqPtr,
                                                                                outputStride: columns
                                                                            )
                                                                            ScaledDCT.applyUnchecked(
                                                                                rows: rows,
                                                                                columns: columns,
                                                                                direction: .inverse,
                                                                                input: deqPtr,
                                                                                output: pPixels,
                                                                                scratch: pScratch
                                                                            )
                                                                        }

                                                                        if visW > 0 && visH > 0 {
                                                                            for ry in 0..<visH {
                                                                                let srcRow = ry * columns
                                                                                let dstRow = (py0 + ry) * width + px0
                                                                                (dstBase + dstRow).update(from: pPixels + srcRow, count: visW)
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
                }
            }
        }
        var planes = [plane0, plane1, plane2]

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
        if q == 0 { return 0.0 }
        if q == 1 || q == -1 {
            let b: Float
            switch channel {
            case 0: b = 1.0 - 0.05465007330715401
            case 1: b = 1.0 - 0.07005449891748593
            default: b = 1.0 - 0.049935103337343655
            }
            return q == 1 ? b : -b
        }
        let fq = Float(q)
        if numericalMode == .libjxl012ARMInteger {
            return fq - quantBiasNumerator * VarDCTReferenceNumerics.reciprocalEstimate(q)
        } else {
            return fq - (quantBiasNumerator / fq)
        }
    }

    @inline(__always)
    private static func reconstructLargeLLFInto(
        dcPlane: [Float],
        bx: Int,
        by: Int,
        blocksX: Int,
        cx: Int,
        cy: Int,
        id: Int,
        output: UnsafeMutablePointer<Float>,
        outputStride: Int
    ) throws {
        guard let (sx, cxPtr) = llfScaleAndCosPointers(cx),
              let (sy, cyPtr) = llfScaleAndCosPointers(cy) else {
            throw VarDCTError.unsupportedStrategy(id)
        }
        let invCount = 1.0 / Double(cx * cy)
        let sqrt2 = 2.0.squareRoot()

        dcPlane.withUnsafeBufferPointer { dcBuf in
            let dcPtr = dcBuf.baseAddress!
            for v in 0..<cy {
                let normV = (v == 0) ? 1.0 : sqrt2
                let scaleY = sy[v]
                let dstRow = v * outputStride
                for u in 0..<cx {
                    let normU = (u == 0) ? 1.0 : sqrt2
                    var sum = 0.0
                    for y in 0..<cy {
                        let cosY = cyPtr[v * cy + y]
                        let rowBase = (by + y) * blocksX + bx
                        for x in 0..<cx {
                            let cosX = cxPtr[u * cx + x]
                            sum += Double(dcPtr[rowBase + x]) * cosX * cosY
                        }
                    }
                    let forwardVal = sum * normU * normV * invCount
                    output[dstRow + u] = Float(forwardVal * sx[u] * scaleY)
                }
            }
        }
    }

    private static func applyAdaptiveDCSmoothing(
        _ dc: [[Float]],
        blocksX: Int,
        blocksY: Int,
        dcStep: [Float],
        budget: ScalarOperationBudget
    ) throws -> [[Float]] {
        var out0 = dc[0]
        var out1 = dc[1]
        var out2 = dc[2]
        let invStep0 = 1.0 / dcStep[0]
        let invStep1 = 1.0 / dcStep[1]
        let invStep2 = 1.0 / dcStep[2]
        try dc[0].withUnsafeBufferPointer { b0 in
            try dc[1].withUnsafeBufferPointer { b1 in
                try dc[2].withUnsafeBufferPointer { b2 in
                    try out0.withUnsafeMutableBufferPointer { o0 in
                        try out1.withUnsafeMutableBufferPointer { o1 in
                            try out2.withUnsafeMutableBufferPointer { o2 in
                                let p0 = b0.baseAddress!, p1 = b1.baseAddress!, p2 = b2.baseAddress!
                                let d0 = o0.baseAddress!, d1 = o1.baseAddress!, d2 = o2.baseAddress!
                                for by in 1..<(blocksY - 1) {
                                    if (by & 15) == 0 { try budget.checkpoint() }
                                    let ym1 = (by - 1) * blocksX
                                    let y0 = by * blocksX
                                    let yp1 = (by + 1) * blocksX

                                    for bx in 1..<(blocksX - 1) {
                                        let idx = y0 + bx

                                        let c0 = p0[idx]
                                        let side0 = (p0[ym1 + bx] + p0[yp1 + bx]) + (p0[y0 + bx - 1] + p0[y0 + bx + 1])
                                        let corner0 = (p0[ym1 + bx - 1] + p0[ym1 + bx + 1]) + (p0[yp1 + bx - 1] + p0[yp1 + bx + 1])
                                        let sm0 = 0.05226273532324128 * c0 + 0.20345139757231578 * side0 + 0.0334829185968739 * corner0
                                        var gap = abs(c0 - sm0) * invStep0

                                        let c1 = p1[idx]
                                        let side1 = (p1[ym1 + bx] + p1[yp1 + bx]) + (p1[y0 + bx - 1] + p1[y0 + bx + 1])
                                        let corner1 = (p1[ym1 + bx - 1] + p1[ym1 + bx + 1]) + (p1[yp1 + bx - 1] + p1[yp1 + bx + 1])
                                        let sm1 = 0.05226273532324128 * c1 + 0.20345139757231578 * side1 + 0.0334829185968739 * corner1
                                        let g1 = abs(c1 - sm1) * invStep1
                                        if g1 > gap { gap = g1 }

                                        let c2 = p2[idx]
                                        let side2 = (p2[ym1 + bx] + p2[yp1 + bx]) + (p2[y0 + bx - 1] + p2[y0 + bx + 1])
                                        let corner2 = (p2[ym1 + bx - 1] + p2[ym1 + bx + 1]) + (p2[yp1 + bx - 1] + p2[yp1 + bx + 1])
                                        let sm2 = 0.05226273532324128 * c2 + 0.20345139757231578 * side2 + 0.0334829185968739 * corner2
                                        let g2 = abs(c2 - sm2) * invStep2
                                        if g2 > gap { gap = g2 }

                                        let factor = max(0.0, min(1.0, 3.0 - 4.0 * gap))
                                        if factor > 0 {
                                            d0[idx] = c0 + (sm0 - c0) * factor
                                            d1[idx] = c1 + (sm1 - c1) * factor
                                            d2[idx] = c2 + (sm2 - c2) * factor
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return [out0, out1, out2]
    }
}
