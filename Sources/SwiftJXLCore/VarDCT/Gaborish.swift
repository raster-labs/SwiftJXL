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

        for y in 0..<height {
            if (y & 15) == 0 { try budget.checkpoint() }
            let rowBase = y * stride
            for x in 0..<width {
                guard input[rowBase + x].isFinite else {
                    throw ScalarModularError.invalidInput("Non-finite sample in Gaborish input")
                }
            }
        }

        var output = [Float](repeating: 0, count: pixelCount)
        let divisor = 1.0 + 4.0 * (weight1 + weight2)
        let w0 = 1.0 / divisor
        let w1 = weight1 / divisor
        let w2 = weight2 / divisor

        for y in 0..<height {
            if (y & 15) == 0 { try budget.checkpoint() }
            let ym1 = max(0, y - 1) * stride
            let y0 = y * stride
            let yp1 = min(height - 1, y + 1) * stride
            let outRow = y * width

            for x in 0..<width {
                let xm1 = max(0, x - 1)
                let xp1 = min(width - 1, x + 1)

                let center = input[y0 + x]
                let cardinal = (input[ym1 + x] + input[yp1 + x]) + (input[y0 + xm1] + input[y0 + xp1])
                let diagonal = (input[ym1 + xm1] + input[ym1 + xp1]) + (input[yp1 + xm1] + input[yp1 + xp1])
                output[outRow + x] = center * w0 + cardinal * w1 + diagonal * w2
            }
        }

        try budget.checkpoint()
        return output
    }
}
