// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift VarDCT/Gaborish.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors' filter, ISO/IEC 18181-1 §K.4.1.
// See Documentation/ThirdParty/libjxl-LICENSE.txt.
import Foundation

package enum Gaborish {
    package static let defaultWeight1: Float = 1.1 * 0.104699568
    package static let defaultWeight2: Float = 1.1 * 0.055680538

    /// Filters the visible rectangle, mirroring its boundary (one-pixel border).
    /// Stride may include transform padding, which must not affect edge pixels.
    /// Returns a tight plane. Caller input is unchanged on every failure.
    package static func apply(_ input: [Float], width: Int, height: Int, stride: Int,
                              weight1: Float = defaultWeight1, weight2: Float = defaultWeight2,
                              budget: ScalarOperationBudget) throws -> [Float] {
        try budget.checkpoint()
        guard width > 0, height > 0, stride >= width,
              weight1.isFinite, weight2.isFinite else { throw VarDCTError.invalidTransform }
        let end = try ScalarOperationBudget.sum(ScalarOperationBudget.product(height - 1, stride), width)
        guard end <= input.count else { throw VarDCTError.invalidTransform }
        let divisor = 1 + 4 * (weight1 + weight2)
        guard divisor.isFinite, divisor > 0 else { throw VarDCTError.invalidTransform }
        let w0 = 1 / divisor, w1 = weight1 / divisor, w2 = weight2 / divisor
        let count = try ScalarOperationBudget.product(width, height)
        try budget.reserveWorkspace(ScalarOperationBudget.product(count, MemoryLayout<Float>.stride))
        var output = [Float](repeating: 0, count: count)
        for y in 0..<height {
            let top = max(0, y - 1) * stride, middle = y * stride, bottom = min(height - 1, y + 1) * stride
            for x in 0..<width {
                if x & 255 == 0 { try budget.checkpoint() }
                let left = max(0, x - 1), right = min(width - 1, x + 1)
                let centre = input[middle + x]
                let sides = (input[middle + left] + input[middle + right]) + (input[top + x] + input[bottom + x])
                let corners = (input[top + left] + input[top + right]) + (input[bottom + left] + input[bottom + right])
                let value = corners * w2 + (sides * w1 + centre * w0)
                guard value.isFinite else { throw VarDCTError.nonFiniteSample }
                output[y * width + x] = value
            }
        }
        try budget.checkpoint()
        return output
    }
}
