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
        var out0 = [Float](repeating: 0, count: pixelCount)
        var out1 = [Float](repeating: 0, count: pixelCount)
        var out2 = [Float](repeating: 0, count: pixelCount)

        var stepInvSigma = [Float](repeating: 0, count: baseSigma.count * 2)
        for i in 0..<baseSigma.count {
            let sigma = baseSigma[i] * sigmaScale
            if sigma > 1e-6 {
                stepInvSigma[i * 2] = invSigmaNum / sigma
                stepInvSigma[i * 2 + 1] = (invSigmaNum * borderSadMul) / sigma
            }
        }

        let offsets = (step == 0) ? step0Offsets : cardinalOffsets
        let useCrossSAD = (step != 2)
        let cs0 = channelScale[0]
        let cs1 = channelScale[1]
        let cs2 = channelScale[2]

        @inline(__always) @Sendable
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

        @inline(__always) @Sendable
        func clampX(_ x: Int) -> Int {
            mirror(x, width)
        }

        @inline(__always) @Sendable
        func clampY(_ y: Int) -> Int {
            mirror(y, height)
        }

        try input[0].withUnsafeBufferPointer { in0Buf in
            try input[1].withUnsafeBufferPointer { in1Buf in
                try input[2].withUnsafeBufferPointer { in2Buf in
                    try out0.withUnsafeMutableBufferPointer { out0Buf in
                        try out1.withUnsafeMutableBufferPointer { out1Buf in
                            try out2.withUnsafeMutableBufferPointer { out2Buf in
                                try stepInvSigma.withUnsafeBufferPointer { sigmaBuf in
                                    nonisolated(unsafe) let p0 = in0Buf.baseAddress!
                                    nonisolated(unsafe) let p1 = in1Buf.baseAddress!
                                    nonisolated(unsafe) let p2 = in2Buf.baseAddress!
                                    nonisolated(unsafe) let o0 = out0Buf.baseAddress!
                                    nonisolated(unsafe) let o1 = out1Buf.baseAddress!
                                    nonisolated(unsafe) let o2 = out2Buf.baseAddress!
                                    nonisolated(unsafe) let invSigBase = sigmaBuf.baseAddress!
                                    let w = width

                                    @inline(__always) @Sendable
                                    func processBoundaryPixel(x: Int, y: Int, by: Int, yBorder: Bool, rowOffset: Int) {
                                        let bIdx2 = (by * blocksX + (x >> 3)) * 2
                                        let invInt = invSigBase[bIdx2]
                                        let centerIndex = rowOffset + x
                                        if invInt == 0 {
                                            o0[centerIndex] = p0[centerIndex]
                                            o1[centerIndex] = p1[centerIndex]
                                            o2[centerIndex] = p2[centerIndex]
                                            return
                                        }
                                        let isBorder = yBorder || ((x & 7) == 0) || ((x & 7) == 7)
                                        let invSigma = isBorder ? invSigBase[bIdx2 + 1] : invInt

                                        var sumW: Float = 1.0
                                        var acc0: Float = p0[centerIndex]
                                        var acc1: Float = p1[centerIndex]
                                        var acc2: Float = p2[centerIndex]

                                        for offset in offsets {
                                            let nx = clampX(x + offset.dx)
                                            let ny = clampY(y + offset.dy)
                                            let nIndex = ny * w + nx

                                            var sad: Float = 0
                                            if useCrossSAD {
                                                for cross in plusCross {
                                                    let ax = clampX(x + cross.cx)
                                                    let ay = clampY(y + cross.cy)
                                                    let bxSample = clampX(x + offset.dx + cross.cx)
                                                    let bySample = clampY(y + offset.dy + cross.cy)
                                                    let aIdx = ay * w + ax
                                                    let bIdx = bySample * w + bxSample

                                                    let d0 = abs(p0[aIdx] - p0[bIdx])
                                                    let d1 = abs(p1[aIdx] - p1[bIdx])
                                                    let d2 = abs(p2[aIdx] - p2[bIdx])
                                                    sad += cs0 * d0 + cs1 * d1 + cs2 * d2
                                                }
                                            } else {
                                                let d0 = abs(p0[centerIndex] - p0[nIndex])
                                                let d1 = abs(p1[centerIndex] - p1[nIndex])
                                                let d2 = abs(p2[centerIndex] - p2[nIndex])
                                                sad = cs0 * d0 + cs1 * d1 + cs2 * d2
                                            }

                                            let weight = max(0, 1.0 - sad * invSigma)
                                            if weight > 0 {
                                                sumW += weight
                                                acc0 += weight * p0[nIndex]
                                                acc1 += weight * p1[nIndex]
                                                acc2 += weight * p2[nIndex]
                                            }
                                        }

                                        let invW = 1.0 / sumW
                                        o0[centerIndex] = acc0 * invW
                                        o1[centerIndex] = acc1 * invW
                                        o2[centerIndex] = acc2 * invW
                                    }

                                    let minMargin = (step == 0) ? 3 : 2
                                    let crossOffsets: (Int, Int, Int, Int, Int) = (0, -1, 1, -w, w)
                                    let step0StrideOffsets: [Int] = [
                                        -1, 1, -w, w,
                                        -w - 1, -w + 1, w - 1, w + 1,
                                        -2, 2, -2 * w, 2 * w
                                    ]
                                    let cardinalStrideOffsets: [Int] = [-1, 1, -w, w]

                                    try step0StrideOffsets.withUnsafeBufferPointer { step0Buf in
                                        try cardinalStrideOffsets.withUnsafeBufferPointer { cardBuf in
                                            nonisolated(unsafe) let step0Ptr = step0Buf.baseAddress!
                                            nonisolated(unsafe) let cardPtr = cardBuf.baseAddress!

                                            @inline(__always) @Sendable
                                            func processRow(_ y: Int) {
                                                let by = y >> 3
                                                let yBorder = ((y & 7) == 0) || ((y & 7) == 7)
                                                let rowOffset = y * w
                                                let rowBlockBase = by * blocksX

                                                if y < minMargin || y >= height - minMargin || w < 2 * minMargin + 1 {
                                                    for x in 0..<w {
                                                        processBoundaryPixel(x: x, y: y, by: by, yBorder: yBorder, rowOffset: rowOffset)
                                                    }
                                                    return
                                                }

                                                for x in 0..<minMargin {
                                                    processBoundaryPixel(x: x, y: y, by: by, yBorder: yBorder, rowOffset: rowOffset)
                                                }

                                                if !useCrossSAD {
                                                    // Step 2 interior fast path: 4 cardinal offsets, single-pixel SAD
                                                    var prevSadRight: Float = -1
                                                    for x in minMargin..<(w - minMargin) {
                                                        let bIdx2 = (rowBlockBase + (x >> 3)) * 2
                                                        let invInt = invSigBase[bIdx2]
                                                        let cIdx = rowOffset + x
                                                        if invInt == 0 {
                                                            o0[cIdx] = p0[cIdx]
                                                            o1[cIdx] = p1[cIdx]
                                                            o2[cIdx] = p2[cIdx]
                                                            prevSadRight = -1
                                                            continue
                                                        }
                                                        let isBorder = yBorder || ((x & 7) == 0) || ((x & 7) == 7)
                                                        let invSigma = isBorder ? invSigBase[bIdx2 + 1] : invInt
                                                        let c0 = p0[cIdx], c1 = p1[cIdx], c2 = p2[cIdx]
                                                        var sumW: Float = 1.0
                                                        var acc0 = c0, acc1 = c1, acc2 = c2

                                                        // k = 0 (-1)
                                                        do {
                                                            let nIdx = cIdx - 1
                                                            let n0 = p0[nIdx], n1 = p1[nIdx], n2 = p2[nIdx]
                                                            let sad: Float
                                                            if prevSadRight >= 0 {
                                                                sad = prevSadRight
                                                            } else {
                                                                sad = cs0 * abs(c0 - n0) + cs1 * abs(c1 - n1) + cs2 * abs(c2 - n2)
                                                            }
                                                            let weight = max(0, 1.0 - sad * invSigma)
                                                            if weight > 0 {
                                                                sumW += weight
                                                                acc0 += weight * n0
                                                                acc1 += weight * n1
                                                                acc2 += weight * n2
                                                            }
                                                        }
                                                        // k = 1 (+1)
                                                        do {
                                                            let nIdx = cIdx + 1
                                                            let n0 = p0[nIdx], n1 = p1[nIdx], n2 = p2[nIdx]
                                                            let sad = cs0 * abs(c0 - n0) + cs1 * abs(c1 - n1) + cs2 * abs(c2 - n2)
                                                            prevSadRight = sad
                                                            let weight = max(0, 1.0 - sad * invSigma)
                                                            if weight > 0 {
                                                                sumW += weight
                                                                acc0 += weight * n0
                                                                acc1 += weight * n1
                                                                acc2 += weight * n2
                                                            }
                                                        }
                                                        // k = 2, 3 (-w, +w)
                                                        for k in 2..<4 {
                                                            let nIdx = cIdx + cardPtr[k]
                                                            let n0 = p0[nIdx], n1 = p1[nIdx], n2 = p2[nIdx]
                                                            let sad = cs0 * abs(c0 - n0) + cs1 * abs(c1 - n1) + cs2 * abs(c2 - n2)
                                                            let weight = max(0, 1.0 - sad * invSigma)
                                                            if weight > 0 {
                                                                sumW += weight
                                                                acc0 += weight * n0
                                                                acc1 += weight * n1
                                                                acc2 += weight * n2
                                                            }
                                                        }
                                                        let invW = 1.0 / sumW
                                                        o0[cIdx] = acc0 * invW
                                                        o1[cIdx] = acc1 * invW
                                                        o2[cIdx] = acc2 * invW
                                                    }
                                                } else if step == 1 {
                                                    // Step 1 interior fast path: 4 cardinal offsets, 5-point plus-cross SAD
                                                    var prevSadRight: Float = -1
                                                    for x in minMargin..<(w - minMargin) {
                                                        let bIdx2 = (rowBlockBase + (x >> 3)) * 2
                                                        let invInt = invSigBase[bIdx2]
                                                        let cIdx = rowOffset + x
                                                        if invInt == 0 {
                                                            o0[cIdx] = p0[cIdx]
                                                            o1[cIdx] = p1[cIdx]
                                                            o2[cIdx] = p2[cIdx]
                                                            prevSadRight = -1
                                                            continue
                                                        }
                                                        let isBorder = yBorder || ((x & 7) == 0) || ((x & 7) == 7)
                                                        let invSigma = isBorder ? invSigBase[bIdx2 + 1] : invInt
                                                        let a0 = cIdx + crossOffsets.0
                                                        let a1 = cIdx + crossOffsets.1
                                                        let a2 = cIdx + crossOffsets.2
                                                        let a3 = cIdx + crossOffsets.3
                                                        let a4 = cIdx + crossOffsets.4
                                                        let c0_0 = p0[a0], c1_0 = p1[a0], c2_0 = p2[a0]
                                                        let c0_1 = p0[a1], c1_1 = p1[a1], c2_1 = p2[a1]
                                                        let c0_2 = p0[a2], c1_2 = p1[a2], c2_2 = p2[a2]
                                                        let c0_3 = p0[a3], c1_3 = p1[a3], c2_3 = p2[a3]
                                                        let c0_4 = p0[a4], c1_4 = p1[a4], c2_4 = p2[a4]
                                                        var sumW: Float = 1.0
                                                        var acc0 = c0_0, acc1 = c1_0, acc2 = c2_0

                                                        for k in 0..<4 {
                                                            let nIdx = cIdx + cardPtr[k]
                                                            var sad: Float = 0
                                                            if k == 0 && prevSadRight >= 0 {
                                                                sad = prevSadRight
                                                            } else {
                                                                let b0 = nIdx + crossOffsets.0
                                                                sad += cs0 * abs(c0_0 - p0[b0]) + cs1 * abs(c1_0 - p1[b0]) + cs2 * abs(c2_0 - p2[b0])
                                                                let b1 = nIdx + crossOffsets.1
                                                                sad += cs0 * abs(c0_1 - p0[b1]) + cs1 * abs(c1_1 - p1[b1]) + cs2 * abs(c2_1 - p2[b1])
                                                                let b2 = nIdx + crossOffsets.2
                                                                sad += cs0 * abs(c0_2 - p0[b2]) + cs1 * abs(c1_2 - p1[b2]) + cs2 * abs(c2_2 - p2[b2])
                                                                let b3 = nIdx + crossOffsets.3
                                                                sad += cs0 * abs(c0_3 - p0[b3]) + cs1 * abs(c1_3 - p1[b3]) + cs2 * abs(c2_3 - p2[b3])
                                                                let b4 = nIdx + crossOffsets.4
                                                                sad += cs0 * abs(c0_4 - p0[b4]) + cs1 * abs(c1_4 - p1[b4]) + cs2 * abs(c2_4 - p2[b4])
                                                                if k == 1 {
                                                                    prevSadRight = sad
                                                                }
                                                            }

                                                            let weight = max(0, 1.0 - sad * invSigma)
                                                            if weight > 0 {
                                                                sumW += weight
                                                                acc0 += weight * p0[nIdx]
                                                                acc1 += weight * p1[nIdx]
                                                                acc2 += weight * p2[nIdx]
                                                            }
                                                        }
                                                        let invW = 1.0 / sumW
                                                        o0[cIdx] = acc0 * invW
                                                        o1[cIdx] = acc1 * invW
                                                        o2[cIdx] = acc2 * invW
                                                    }
                                                } else {
                                                    // Step 0 interior fast path: 12 offsets, 5-point plus-cross SAD
                                                    var prevSadRight1: Float = -1
                                                    var prevSadRight2_m1: Float = -1
                                                    var prevSadRight2_m2: Float = -1
                                                    for x in minMargin..<(w - minMargin) {
                                                        let bIdx2 = (rowBlockBase + (x >> 3)) * 2
                                                        let invInt = invSigBase[bIdx2]
                                                        let cIdx = rowOffset + x
                                                        if invInt == 0 {
                                                            o0[cIdx] = p0[cIdx]
                                                            o1[cIdx] = p1[cIdx]
                                                            o2[cIdx] = p2[cIdx]
                                                            prevSadRight1 = -1
                                                            prevSadRight2_m2 = prevSadRight2_m1
                                                            prevSadRight2_m1 = -1
                                                            continue
                                                        }
                                                        let isBorder = yBorder || ((x & 7) == 0) || ((x & 7) == 7)
                                                        let invSigma = isBorder ? invSigBase[bIdx2 + 1] : invInt
                                                        let a0 = cIdx + crossOffsets.0
                                                        let a1 = cIdx + crossOffsets.1
                                                        let a2 = cIdx + crossOffsets.2
                                                        let a3 = cIdx + crossOffsets.3
                                                        let a4 = cIdx + crossOffsets.4
                                                        let c0_0 = p0[a0], c1_0 = p1[a0], c2_0 = p2[a0]
                                                        let c0_1 = p0[a1], c1_1 = p1[a1], c2_1 = p2[a1]
                                                        let c0_2 = p0[a2], c1_2 = p1[a2], c2_2 = p2[a2]
                                                        let c0_3 = p0[a3], c1_3 = p1[a3], c2_3 = p2[a3]
                                                        let c0_4 = p0[a4], c1_4 = p1[a4], c2_4 = p2[a4]
                                                        var sumW: Float = 1.0
                                                        var acc0 = c0_0, acc1 = c1_0, acc2 = c2_0

                                                        for k in 0..<12 {
                                                            let nIdx = cIdx + step0Ptr[k]
                                                            var sad: Float = 0
                                                            if k == 0 && prevSadRight1 >= 0 {
                                                                sad = prevSadRight1
                                                            } else if k == 8 && prevSadRight2_m2 >= 0 {
                                                                sad = prevSadRight2_m2
                                                            } else {
                                                                let b0 = nIdx + crossOffsets.0
                                                                sad += cs0 * abs(c0_0 - p0[b0]) + cs1 * abs(c1_0 - p1[b0]) + cs2 * abs(c2_0 - p2[b0])
                                                                let b1 = nIdx + crossOffsets.1
                                                                sad += cs0 * abs(c0_1 - p0[b1]) + cs1 * abs(c1_1 - p1[b1]) + cs2 * abs(c2_1 - p2[b1])
                                                                let b2 = nIdx + crossOffsets.2
                                                                sad += cs0 * abs(c0_2 - p0[b2]) + cs1 * abs(c1_2 - p1[b2]) + cs2 * abs(c2_2 - p2[b2])
                                                                let b3 = nIdx + crossOffsets.3
                                                                sad += cs0 * abs(c0_3 - p0[b3]) + cs1 * abs(c1_3 - p1[b3]) + cs2 * abs(c2_3 - p2[b3])
                                                                let b4 = nIdx + crossOffsets.4
                                                                sad += cs0 * abs(c0_4 - p0[b4]) + cs1 * abs(c1_4 - p1[b4]) + cs2 * abs(c2_4 - p2[b4])
                                                                if k == 1 {
                                                                    prevSadRight1 = sad
                                                                } else if k == 9 {
                                                                    prevSadRight2_m2 = prevSadRight2_m1
                                                                    prevSadRight2_m1 = sad
                                                                }
                                                            }

                                                            let weight = max(0, 1.0 - sad * invSigma)
                                                            if weight > 0 {
                                                                sumW += weight
                                                                acc0 += weight * p0[nIdx]
                                                                acc1 += weight * p1[nIdx]
                                                                acc2 += weight * p2[nIdx]
                                                            }
                                                        }
                                                        let invW = 1.0 / sumW
                                                        o0[cIdx] = acc0 * invW
                                                        o1[cIdx] = acc1 * invW
                                                        o2[cIdx] = acc2 * invW
                                                    }
                                                }

                                                for x in (w - minMargin)..<w {
                                                    processBoundaryPixel(x: x, y: y, by: by, yBorder: yBorder, rowOffset: rowOffset)
                                                }
                                            }

                                            let workers = min(max(1, budget.maximumWorkers), 8)
                                            if workers > 1 && height >= 64 {
                                                try budget.checkpoint()
                                                let bandCount = min(workers, height)
                                                DispatchQueue.concurrentPerform(iterations: bandCount) { band in
                                                    let y0 = (band * height) / bandCount
                                                    let y1 = ((band + 1) * height) / bandCount
                                                    for y in y0..<y1 {
                                                        processRow(y)
                                                    }
                                                }
                                                try budget.checkpoint()
                                            } else {
                                                for y in 0..<height {
                                                    if (y & 7) == 0 { try budget.checkpoint() }
                                                    processRow(y)
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

        return [out0, out1, out2]
    }
}
