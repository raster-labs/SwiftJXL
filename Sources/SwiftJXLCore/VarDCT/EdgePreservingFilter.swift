// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Three-stage Edge-Preserving Filter (EPF) per ISO/IEC 18181-1 §10.4.2.
package enum EdgePreservingFilter {
    private static let quantMul: Float = 0.27878788
    private static let invSigmaNum: Float = 1.1715728752538099024 // 4 * (1 - sqrt(0.5))

    private static let step0Offsets: [(dx: Int, dy: Int)] = [
        (-1, 0), (1, 0), (0, -1), (0, 1),
        (-1, -1), (1, -1), (-1, 1), (1, 1),
        (-2, 0), (2, 0), (0, -2), (0, 2)
    ]

    private static let cardinalOffsets: [(dx: Int, dy: Int)] = [
        (-1, 0), (1, 0), (0, -1), (0, 1)
    ]

    private static let plusCross: [(cx: Int, cy: Int)] = [
        (0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)
    ]

    package static let defaultChannelScale: [Float] = [40.0, 5.0, 3.5]
    package static let defaultPass0SigmaScale: Float = 1.65
    package static let defaultPass2SigmaScale: Float = 0.65
    package static let defaultBorderSadMul: Float = 2.0 / 3.0
    package static let defaultSharpLut: [Float] = [
        0.0 / 7.0, 1.0 / 7.0, 2.0 / 7.0, 3.0 / 7.0,
        4.0 / 7.0, 5.0 / 7.0, 6.0 / 7.0, 7.0 / 7.0
    ]

    package static func apply(
        _ planes: [[Float]],
        width: Int,
        height: Int,
        iterations: Int,
        quantisation: [UInt32],
        sharpness: [Int32],
        globalScale: UInt32,
        channelScale: [Float] = defaultChannelScale,
        pass0SigmaScale: Float = defaultPass0SigmaScale,
        pass2SigmaScale: Float = defaultPass2SigmaScale,
        borderSadMul: Float = defaultBorderSadMul,
        sharpLut: [Float] = defaultSharpLut,
        budget: ScalarOperationBudget
    ) throws -> [[Float]] {
        try budget.checkpoint()
        guard planes.count == 3,
              width > 0, height > 0,
              (0...3).contains(iterations),
              globalScale > 0,
              channelScale.count == 3,
              sharpLut.count == 8,
              pass0SigmaScale.isFinite, pass0SigmaScale > 0,
              pass2SigmaScale.isFinite, pass2SigmaScale > 0,
              borderSadMul.isFinite, borderSadMul > 0,
              channelScale.allSatisfy({ $0.isFinite && $0 >= 0 }),
              sharpLut.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw ScalarModularError.invalidInput("Invalid EPF parameters")
        }

        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (widthPlus7, wOverflow) = width.addingReportingOverflow(7)
        let (heightPlus7, hOverflow) = height.addingReportingOverflow(7)
        guard !pixelOverflow, !wOverflow, !hOverflow else {
            throw ScalarModularError.invalidInput("EPF dimensions overflow")
        }
        let blocksX = widthPlus7 / 8
        let blocksY = heightPlus7 / 8
        let (blockCount, blockOverflow) = blocksX.multipliedReportingOverflow(by: blocksY)
        let (planeBytes, planeByteOverflow) = pixelCount.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        let (workspaceBytes, wsOverflow) = planeBytes.multipliedReportingOverflow(by: 6)
        guard !blockOverflow, !planeByteOverflow, !wsOverflow,
              quantisation.count == blockCount,
              sharpness.count == blockCount else {
            throw ScalarModularError.invalidInput("Invalid EPF block map dimensions")
        }

        try budget.reserveWorkspace(workspaceBytes)

        for c in 0..<3 {
            guard planes[c].count == pixelCount else {
                throw ScalarModularError.invalidInput("EPF plane size mismatch")
            }
            for v in planes[c] {
                guard v.isFinite else {
                    throw ScalarModularError.invalidInput("Non-finite sample in EPF input")
                }
            }
        }

        for i in 0..<blockCount {
            guard quantisation[i] > 0, (0..<8).contains(Int(sharpness[i])) else {
                throw ScalarModularError.invalidInput("Invalid EPF block quantisation or sharpness")
            }
        }

        if iterations == 0 {
            return planes
        }

        // Precompute per-block base sigma:
        // quant = 65536 / (globalScale * quant_field[b])
        // sigma_base = quant * epf_quant_mul * epf_sharp_lut[sharpness[b]]
        let invGlobalScale = 65536.0 / Float(globalScale)
        var baseSigma = [Float](repeating: 0, count: blockCount)
        var anyPositiveSigma = false
        for i in 0..<blockCount {
            let s = sharpLut[Int(sharpness[i])]
            let sigma = (invGlobalScale / Float(quantisation[i])) * quantMul * s
            baseSigma[i] = sigma
            if sigma > 1e-6 {
                anyPositiveSigma = true
            }
        }

        if !anyPositiveSigma {
            return planes
        }

        let steps: [Int]
        switch iterations {
        case 3: steps = [0, 1, 2]
        case 2: steps = [1, 2]
        case 1: steps = [1]
        default: steps = []
        }

        var current = planes
        for step in steps {
            try budget.checkpoint()
            let sigmaScale: Float
            switch step {
            case 0: sigmaScale = pass0SigmaScale
            case 1: sigmaScale = 1.0
            default: sigmaScale = pass2SigmaScale
            }
            current = try runStep(
                current,
                width: width,
                height: height,
                blocksX: blocksX,
                step: step,
                baseSigma: baseSigma,
                sigmaScale: sigmaScale,
                channelScale: channelScale,
                borderSadMul: borderSadMul,
                budget: budget
            )
        }

        try budget.checkpoint()
        return current
    }

    private static func runStep(
        _ input: [[Float]],
        width: Int,
        height: Int,
        blocksX: Int,
        step: Int,
        baseSigma: [Float],
        sigmaScale: Float,
        channelScale: [Float],
        borderSadMul: Float,
        budget: ScalarOperationBudget
    ) throws -> [[Float]] {
        let pixelCount = width * height
        var output = [
            [Float](repeating: 0, count: pixelCount),
            [Float](repeating: 0, count: pixelCount),
            [Float](repeating: 0, count: pixelCount)
        ]

        let offsets = (step == 0) ? step0Offsets : cardinalOffsets
        let useCrossSAD = (step != 2)
        let cs0 = channelScale[0]
        let cs1 = channelScale[1]
        let cs2 = channelScale[2]

        @inline(__always)
        func mirror(_ coord: Int, _ size: Int) -> Int {
            if size <= 1 { return 0 }
            var c = coord
            while c < 0 || c >= size {
                if c < 0 {
                    c = -c - 1
                } else {
                    c = 2 * size - 1 - c
                }
            }
            return c
        }

        @inline(__always)
        func clampX(_ x: Int) -> Int {
            mirror(x, width)
        }

        @inline(__always)
        func clampY(_ y: Int) -> Int {
            mirror(y, height)
        }

        for y in 0..<height {
            if (y & 7) == 0 { try budget.checkpoint() }
            let by = y >> 3
            let yBorder = ((y & 7) == 0) || ((y & 7) == 7)
            let rowOffset = y * width

            for x in 0..<width {
                let bx = x >> 3
                let sigma = baseSigma[by * blocksX + bx] * sigmaScale
                let centerIndex = rowOffset + x
                if sigma <= 1e-6 {
                    output[0][centerIndex] = input[0][centerIndex]
                    output[1][centerIndex] = input[1][centerIndex]
                    output[2][centerIndex] = input[2][centerIndex]
                    continue
                }

                let isBorder = yBorder || ((x & 7) == 0) || ((x & 7) == 7)
                let sadMul = isBorder ? borderSadMul : 1.0
                let invSigma = (invSigmaNum * sadMul) / sigma

                var sumW: Float = 1.0
                var acc0: Float = input[0][centerIndex]
                var acc1: Float = input[1][centerIndex]
                var acc2: Float = input[2][centerIndex]

                for offset in offsets {
                    let nx = clampX(x + offset.dx)
                    let ny = clampY(y + offset.dy)
                    let nIndex = ny * width + nx

                    var sad: Float = 0
                    if useCrossSAD {
                        for cross in plusCross {
                            let ax = clampX(x + cross.cx)
                            let ay = clampY(y + cross.cy)
                            let bxSample = clampX(x + offset.dx + cross.cx)
                            let bySample = clampY(y + offset.dy + cross.cy)
                            let aIdx = ay * width + ax
                            let bIdx = bySample * width + bxSample

                            let d0 = abs(input[0][aIdx] - input[0][bIdx])
                            let d1 = abs(input[1][aIdx] - input[1][bIdx])
                            let d2 = abs(input[2][aIdx] - input[2][bIdx])
                            sad += cs0 * d0 + cs1 * d1 + cs2 * d2
                        }
                    } else {
                        let d0 = abs(input[0][centerIndex] - input[0][nIndex])
                        let d1 = abs(input[1][centerIndex] - input[1][nIndex])
                        let d2 = abs(input[2][centerIndex] - input[2][nIndex])
                        sad = cs0 * d0 + cs1 * d1 + cs2 * d2
                    }

                    let w = max(0, 1.0 - sad * invSigma)
                    if w > 0 {
                        sumW += w
                        acc0 += w * input[0][nIndex]
                        acc1 += w * input[1][nIndex]
                        acc2 += w * input[2][nIndex]
                    }
                }

                let invW = 1.0 / sumW
                output[0][centerIndex] = acc0 * invW
                output[1][centerIndex] = acc1 * invW
                output[2][centerIndex] = acc2 * invW
            }
        }

        return output
    }
}
