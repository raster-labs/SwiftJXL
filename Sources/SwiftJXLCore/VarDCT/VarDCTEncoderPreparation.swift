// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift VarDCT/Gaborish.swift and Codec/VarDCTEncoder.swift
// at 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause; see libjxl-LICENSE.txt.
import Foundation

package enum VarDCTEncoderPreparation {
    /// Tuned encoder prefilter, not a mathematical inverse. Repeats the edge
    /// sample as prescribed by libjxl WrapMirror, including one-pixel images.
    /// Padding is excluded; the caller extends filtered visible pixels for DCT.
    package static func inverseGaborish(_ input: [Float], width: Int, height: Int,
                                       budget: ScalarOperationBudget) throws -> [Float] {
        try budget.checkpoint()
        guard width > 0, height > 0,
              try ScalarOperationBudget.product(width, height) == input.count else {
            throw VarDCTError.invalidTransform
        }
        try budget.reserveWorkspace(ScalarOperationBudget.product(input.count, MemoryLayout<Float>.stride))
        let g: [Float] = [-0.09495815671340026, -0.041031725066768575,
            0.013710004822696948, 0.006510206083837737, -0.0014789063378272242]
        let normalise = Float(1 / (1 + Double(4 * (g[0] + g[1] + g[2] + g[4] + 2 * g[3]))))
        let w = g.map { $0 * normalise }
        func mirror(_ coordinate: Int, _ size: Int) -> Int {
            if size == 1 { return 0 }
            if coordinate < 0 { return -coordinate - 1 }
            if coordinate >= size { return size - 1 - (coordinate - size) }
            return coordinate
        }
        var output = [Float](repeating: 0, count: input.count)
        for y in 0..<height { for x in 0..<width {
            if x & 255 == 0 { try budget.checkpoint() }
            func p(_ dx: Int, _ dy: Int) -> Float { input[mirror(y + dy, height) * width + mirror(x + dx, width)] }
            let axis1 = p(-1,0) + p(1,0) + p(0,-1) + p(0,1)
            let diag1 = p(-1,-1) + p(1,-1) + p(-1,1) + p(1,1)
            let axis2 = p(-2,0) + p(2,0) + p(0,-2) + p(0,2)
            let knight = p(-2,-1) + p(-2,1) + p(2,-1) + p(2,1) + p(-1,-2) + p(1,-2) + p(-1,2) + p(1,2)
            let corner = p(-2,-2) + p(2,-2) + p(-2,2) + p(2,2)
            let value = normalise * p(0,0) + w[0] * axis1 + w[1] * diag1 + w[2] * axis2 + w[3] * knight + w[4] * corner
            guard value.isFinite else { throw VarDCTError.nonFiniteSample }
            output[y * width + x] = value
        } }
        try budget.checkpoint()
        return output
    }

    /// The predecessor's distance-scaled variance heuristic. This is not a
    /// perceptual error guarantee. Input is original XYB, before B-Y decorrelation.
    static func quantisation(_ patch: [[Float]], distance: Float) throws -> Int32 {
        guard patch.count == 3, patch.allSatisfy({ $0.count == 64 }),
              distance.isFinite, distance > 0 else { throw VarDCTError.invalidTransform }
        let scale = 1 / max(distance, 0.5)
        let maximum = min(Float(48), max(6, (24 * scale).rounded()))
        let multiplier = min(Float(200), max(25, (100 * scale).rounded()))
        var detail: Float = 0
        for c in 0..<3 {
            var sum: Float = 0, squared: Float = 0
            for value in patch[c] {
                guard value.isFinite else { throw VarDCTError.nonFiniteSample }
                sum += value; squared += value * value
            }
            let mean = sum / 64, variance = max(0, squared / 64 - mean * mean)
            detail += variance.squareRoot() * (c == 1 ? 2 : 1)
        }
        let value = min(maximum, max(3, 5 + (multiplier * detail / 4).rounded()))
        guard value.isFinite else { throw VarDCTError.nonFiniteSample }
        return Int32(value)
    }
}
