// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Gaborish 3x3 smoothing convolution per ISO/IEC 18181-1 §10.4.1.
package enum Gaborish {
    package static let defaultWeight1: Float = 0.115169525
    package static let defaultWeight2: Float = 0.061248592

    package static func apply(
        _ input: [Float],
        width: Int,
        height: Int,
        stride: Int,
        weight1: Float = defaultWeight1,
        weight2: Float = defaultWeight2,
        budget: ScalarOperationBudget
    ) throws -> [Float] {
        try budget.checkpoint()
        guard width > 0, height > 0, stride >= width,
              weight1.isFinite, weight1 >= 0,
              weight2.isFinite, weight2 >= 0 else {
            throw ScalarModularError.invalidInput("Invalid Gaborish parameters")
        }
        let (lastRowOffset, rowOverflow) = (height - 1).multipliedReportingOverflow(by: stride)
        let (requiredInputCount, inputOverflow) = lastRowOffset.addingReportingOverflow(width)
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (workspaceBytes, byteOverflow) = pixelCount.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !rowOverflow, !inputOverflow, !pixelOverflow, !byteOverflow,
              requiredInputCount <= input.count else {
            throw ScalarModularError.invalidInput("Gaborish buffer dimensions out of bounds")
        }

        try budget.reserveWorkspace(workspaceBytes)

        var output = [Float](repeating: 0, count: pixelCount)
        let divisor = 1.0 + 4.0 * (weight1 + weight2)
        let w0 = 1.0 / divisor
        let w1 = weight1 / divisor
        let w2 = weight2 / divisor

        try input.withUnsafeBufferPointer { inBuf in
            try output.withUnsafeMutableBufferPointer { outBuf in
                let src = inBuf.baseAddress!
                let dst = outBuf.baseAddress!

                for y in 0..<height {
                    if (y & 15) == 0 { try budget.checkpoint() }
                    let ym1 = max(0, y - 1) * stride
                    let y0 = y * stride
                    let yp1 = min(height - 1, y + 1) * stride
                    let outRow = y * width

                    if width >= 3 {
                        do {
                            let xm1 = 0
                            let xp1 = 1
                            let center = src[y0]
                            let cardinal = (src[ym1] + src[yp1]) + (src[y0 + xm1] + src[y0 + xp1])
                            let diagonal = (src[ym1 + xm1] + src[ym1 + xp1]) + (src[yp1 + xm1] + src[yp1 + xp1])
                            let val = center * w0 + cardinal * w1 + diagonal * w2
                            guard center.isFinite, val.isFinite else {
                                throw ScalarModularError.invalidInput("Non-finite sample in Gaborish input")
                            }
                            dst[outRow] = val
                        }
                        for x in 1..<(width - 1) {
                            let center = src[y0 + x]
                            let cardinal = (src[ym1 + x] + src[yp1 + x]) + (src[y0 + x - 1] + src[y0 + x + 1])
                            let diagonal = (src[ym1 + x - 1] + src[ym1 + x + 1]) + (src[yp1 + x - 1] + src[yp1 + x + 1])
                            let val = center * w0 + cardinal * w1 + diagonal * w2
                            guard center.isFinite, val.isFinite else {
                                throw ScalarModularError.invalidInput("Non-finite sample in Gaborish input")
                            }
                            dst[outRow + x] = val
                        }
                        do {
                            let x = width - 1
                            let xm1 = x - 1
                            let xp1 = x
                            let center = src[y0 + x]
                            let cardinal = (src[ym1 + x] + src[yp1 + x]) + (src[y0 + xm1] + src[y0 + xp1])
                            let diagonal = (src[ym1 + xm1] + src[ym1 + xp1]) + (src[yp1 + xm1] + src[yp1 + xp1])
                            let val = center * w0 + cardinal * w1 + diagonal * w2
                            guard center.isFinite, val.isFinite else {
                                throw ScalarModularError.invalidInput("Non-finite sample in Gaborish input")
                            }
                            dst[outRow + x] = val
                        }
                    } else {
                        for x in 0..<width {
                            let xm1 = max(0, x - 1)
                            let xp1 = min(width - 1, x + 1)
                            let center = src[y0 + x]
                            let cardinal = (src[ym1 + x] + src[yp1 + x]) + (src[y0 + xm1] + src[y0 + xp1])
                            let diagonal = (src[ym1 + xm1] + src[ym1 + xp1]) + (src[yp1 + xm1] + src[yp1 + xp1])
                            let val = center * w0 + cardinal * w1 + diagonal * w2
                            guard center.isFinite, val.isFinite else {
                                throw ScalarModularError.invalidInput("Non-finite sample in Gaborish input")
                            }
                            dst[outRow + x] = val
                        }
                    }
                }
            }
        }

        try budget.checkpoint()
        return output
    }
}
