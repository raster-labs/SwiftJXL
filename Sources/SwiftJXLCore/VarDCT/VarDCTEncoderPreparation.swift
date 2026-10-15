// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift VarDCT/Gaborish.swift and Codec/VarDCTEncoder.swift
// at 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause; see libjxl-LICENSE.txt.
import Foundation

package enum VarDCTEncoderPreparation {
    /// Exact operation-owned conversion for meaningful eight-bit samples. The
    /// caller still validates each sample before indexing; no source is cached.
    struct EightBitConversion {
        let linear: [Double]
        let grayscale: [(Float, Float, Float)]

        init(grayscale: Bool, budget: ScalarOperationBudget) throws {
            try budget.checkpoint()
            try budget.reserveWorkspace(256 * (MemoryLayout<Double>.stride +
                (grayscale ? MemoryLayout<(Float, Float, Float)>.stride : 0)))
            var linear = [Double](); linear.reserveCapacity(256)
            var gray = [(Float, Float, Float)]()
            if grayscale { gray.reserveCapacity(256) }
            for sample in 0..<256 {
                if sample & 63 == 0 { try budget.checkpoint() }
                let v = Double(sample) / Double(255)
                let value = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                linear.append(value)
                if grayscale {
                    let p = try DefaultOpsin.forward((value, value, value))
                    gray.append((Float(p.X), Float(p.Y), Float(p.B)))
                }
            }
            try budget.checkpoint()
            self.linear = linear; self.grayscale = gray
        }
    }

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
        try input.withUnsafeBufferPointer { source in
            try output.withUnsafeMutableBufferPointer { target in
                for y in 0..<height {
                    let row = y * width
                    let ym1 = mirror(y - 1, height) * width, yp1 = mirror(y + 1, height) * width
                    let ym2 = mirror(y - 2, height) * width, yp2 = mirror(y + 2, height) * width
                    for x in 0..<width {
                        if x & 255 == 0 { try budget.checkpoint() }
                        let xm1 = mirror(x - 1, width), xp1 = mirror(x + 1, width)
                        let xm2 = mirror(x - 2, width), xp2 = mirror(x + 2, width)
                        // Preserve the scalar expression's left-to-right Float
                        // sums; only address calculation and ownership change.
                        let axis1 = source[row + xm1] + source[row + xp1] + source[ym1 + x] + source[yp1 + x]
                        let diag1 = source[ym1 + xm1] + source[ym1 + xp1] + source[yp1 + xm1] + source[yp1 + xp1]
                        let axis2 = source[row + xm2] + source[row + xp2] + source[ym2 + x] + source[yp2 + x]
                        let knight = source[ym1 + xm2] + source[yp1 + xm2] + source[ym1 + xp2] + source[yp1 + xp2] + source[ym2 + xm1] + source[ym2 + xp1] + source[yp2 + xm1] + source[yp2 + xp1]
                        let corner = source[ym2 + xm2] + source[ym2 + xp2] + source[yp2 + xm2] + source[yp2 + xp2]
                        let value = normalise * source[row + x] + w[0] * axis1 + w[1] * diag1 + w[2] * axis2 + w[3] * knight + w[4] * corner
                        guard value.isFinite else { throw VarDCTError.nonFiniteSample }
                        target[row + x] = value
                    }
                }
            }
        }
        try budget.checkpoint()
        return output
    }

    /// Three consecutive 64-sample XYB planes in an admitted synchronous borrow.
    /// Channel and row-major summation order matches the array reference below.
    static func quantisation(_ patch: UnsafeBufferPointer<Float>, distance: Float) throws -> Int32 {
        guard patch.count == 192, distance.isFinite, distance > 0 else { throw VarDCTError.invalidTransform }
        let scale = 1 / max(distance, 0.5)
        let maximum = min(Float(48), max(6, (24 * scale).rounded()))
        let multiplier = min(Float(200), max(25, (100 * scale).rounded()))
        var detail: Float = 0
        for c in 0..<3 {
            var sum: Float = 0, squared: Float = 0
            for i in 0..<64 {
                let value = patch[c * 64 + i]
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
