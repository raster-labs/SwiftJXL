// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Forward pixel conversion, inverse-Gaborish pre-filtering, and local adaptive
/// quantisation field (`qf`) estimation for the clean-room VarDCT encoder.
package enum VarDCTEncoderPreparation {
    /// Precomputed 8-bit IEC 61966-2-1 sRGB to linear sRGB and greyscale XYB lookup tables.
    package struct EightBitConversion: Sendable {
        package let linear: [Double]
        package let grayscale: [(Float, Float, Float)]

        package init(grayscale: Bool, budget: ScalarOperationBudget) throws {
            try budget.checkpoint()
            let linearBytes = 256 * MemoryLayout<Double>.stride
            let grayBytes = grayscale ? 256 * MemoryLayout<(Float, Float, Float)>.stride : 0
            try budget.reserveWorkspace(linearBytes + grayBytes)

            var lin = [Double](repeating: 0, count: 256)
            for sample in 0..<256 {
                let v = Double(sample) / 255.0
                lin[sample] = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            self.linear = lin

            if grayscale {
                var gray = [(Float, Float, Float)]()
                gray.reserveCapacity(256)
                for sample in 0..<256 {
                    let l = lin[sample]
                    let xyb = try DefaultOpsin.forward((l, l, l))
                    gray.append((Float(xyb.X), Float(xyb.Y), Float(xyb.B)))
                }
                self.grayscale = gray
            } else {
                self.grayscale = []
            }
        }
    }

    /// Applies the 5x5 damped inverse-Gaborish pre-filter with mirror boundary reflection.
    package static func inverseGaborish(
        _ input: [Float],
        width: Int,
        height: Int,
        budget: ScalarOperationBudget
    ) throws -> [Float] {
        try budget.checkpoint()
        guard width > 0, height > 0 else {
            throw VarDCTError.invalidTransform
        }
        let count = try ScalarOperationBudget.product(width, height)
        guard input.count == count else {
            throw VarDCTError.invalidTransform
        }
        for sample in input {
            guard sample.isFinite else {
                throw VarDCTError.nonFiniteSample
            }
        }
        try budget.reserveWorkspace(ScalarOperationBudget.product(count, MemoryLayout<Float>.stride))

        let g0: Float = -0.09495815671340026
        let g1: Float = -0.041031725066768575
        let g2: Float = 0.013710004822696948
        let g3: Float = 0.006510206083837737
        let g4: Float = -0.0014789063378272242
        let normalise = Float(1.0 / (1.0 + Double(4.0 * (g0 + g1 + g2 + g4 + 2.0 * g3))))
        let w0 = g0 * normalise
        let w1 = g1 * normalise
        let w2 = g2 * normalise
        let w3 = g3 * normalise
        let w4 = g4 * normalise

        @inline(__always)
        func mirror(_ coordinate: Int, _ size: Int) -> Int {
            if size == 1 { return 0 }
            if coordinate < 0 { return -coordinate - 1 }
            if coordinate >= size { return size - 1 - (coordinate - size) }
            return coordinate
        }

        var output = [Float](repeating: 0, count: count)
        input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    if y >= 2 && y + 2 < height && width >= 5 {
                        let rM2 = (y - 2) * width
                        let rM1 = (y - 1) * width
                        let r0  = y * width
                        let rP1 = (y + 1) * width
                        let rP2 = (y + 2) * width

                        for x in [0, 1, width - 2, width - 1] {
                            let xm2 = mirror(x - 2, width)
                            let xm1 = mirror(x - 1, width)
                            let xp1 = mirror(x + 1, width)
                            let xp2 = mirror(x + 2, width)
                            let axis1 = src[r0 + xm1] + src[r0 + xp1] + src[rM1 + x] + src[rP1 + x]
                            let diag1 = src[rM1 + xm1] + src[rM1 + xp1] + src[rP1 + xm1] + src[rP1 + xp1]
                            let axis2 = src[r0 + xm2] + src[r0 + xp2] + src[rM2 + x] + src[rP2 + x]
                            let knight = src[rM1 + xm2] + src[rP1 + xm2] + src[rM1 + xp2] + src[rP1 + xp2]
                                + src[rM2 + xm1] + src[rM2 + xp1] + src[rP2 + xm1] + src[rP2 + xp1]
                            let corner = src[rM2 + xm2] + src[rM2 + xp2] + src[rP2 + xm2] + src[rP2 + xp2]
                            dst[r0 + x] = normalise * src[r0 + x] + w0 * axis1 + w1 * diag1 + w2 * axis2 + w3 * knight + w4 * corner
                        }

                        for x in 2..<(width - 2) {
                            let axis1 = src[r0 + x - 1] + src[r0 + x + 1] + src[rM1 + x] + src[rP1 + x]
                            let diag1 = src[rM1 + x - 1] + src[rM1 + x + 1] + src[rP1 + x - 1] + src[rP1 + x + 1]
                            let axis2 = src[r0 + x - 2] + src[r0 + x + 2] + src[rM2 + x] + src[rP2 + x]
                            let knight = src[rM1 + x - 2] + src[rP1 + x - 2] + src[rM1 + x + 2] + src[rP1 + x + 2]
                                + src[rM2 + x - 1] + src[rM2 + x + 1] + src[rP2 + x - 1] + src[rP2 + x + 1]
                            let corner = src[rM2 + x - 2] + src[rM2 + x + 2] + src[rP2 + x - 2] + src[rP2 + x + 2]
                            dst[r0 + x] = normalise * src[r0 + x] + w0 * axis1 + w1 * diag1 + w2 * axis2 + w3 * knight + w4 * corner
                        }
                    } else {
                        let rM2 = mirror(y - 2, height) * width
                        let rM1 = mirror(y - 1, height) * width
                        let r0  = y * width
                        let rP1 = mirror(y + 1, height) * width
                        let rP2 = mirror(y + 2, height) * width
                        for x in 0..<width {
                            let xm2 = mirror(x - 2, width)
                            let xm1 = mirror(x - 1, width)
                            let xp1 = mirror(x + 1, width)
                            let xp2 = mirror(x + 2, width)
                            let axis1 = src[r0 + xm1] + src[r0 + xp1] + src[rM1 + x] + src[rP1 + x]
                            let diag1 = src[rM1 + xm1] + src[rM1 + xp1] + src[rP1 + xm1] + src[rP1 + xp1]
                            let axis2 = src[r0 + xm2] + src[r0 + xp2] + src[rM2 + x] + src[rP2 + x]
                            let knight = src[rM1 + xm2] + src[rP1 + xm2] + src[rM1 + xp2] + src[rP1 + xp2]
                                + src[rM2 + xm1] + src[rM2 + xp1] + src[rP2 + xm1] + src[rP2 + xp1]
                            let corner = src[rM2 + xm2] + src[rM2 + xp2] + src[rP2 + xm2] + src[rP2 + xp2]
                            dst[r0 + x] = normalise * src[r0 + x] + w0 * axis1 + w1 * diag1 + w2 * axis2 + w3 * knight + w4 * corner
                        }
                    }
                }
            }
        }
        return output
    }

    /// Computes local adaptive quantisation (`qf`) for a 3-channel 8x8 XYB patch.
    package static func quantisation(_ patch: [[Float]], distance: Float) throws -> Int32 {
        guard patch.count == 3, patch.allSatisfy({ $0.count == 64 }) else {
            throw VarDCTError.invalidTransform
        }
        var flat = [Float]()
        flat.reserveCapacity(192)
        for c in 0..<3 {
            flat.append(contentsOf: patch[c])
        }
        return try flat.withUnsafeBufferPointer { try quantisation($0, distance: distance) }
    }

    /// Computes local adaptive quantisation (`qf`) from a borrowed 192-element (`3 x 64`) XYB buffer.
    package static func quantisation(_ patch: UnsafeBufferPointer<Float>, distance: Float) throws -> Int32 {
        guard distance.isFinite, distance > 0, patch.count == 192 else {
            throw VarDCTError.invalidTransform
        }
        for i in 0..<192 {
            guard patch[i].isFinite else {
                throw VarDCTError.nonFiniteSample
            }
        }

        let channelWeights: (Double, Double, Double) = (0.35, 1.0, 0.15)
        let weights = [channelWeights.0, channelWeights.1, channelWeights.2]
        var weightedVariance = 0.0
        var weightedGradient = 0.0

        for c in 0..<3 {
            let base = c * 64
            var sum = 0.0
            for i in 0..<64 {
                sum += Double(patch[base + i])
            }
            let mean = sum / 64.0
            var varSum = 0.0
            for i in 0..<64 {
                let d = Double(patch[base + i]) - mean
                varSum += d * d
            }
            weightedVariance += weights[c] * (varSum / 64.0)

            var gradSum = 0.0
            for y in 0..<8 {
                let row = base + y * 8
                for x in 0..<8 {
                    if x + 1 < 8 {
                        let dx = abs(Double(patch[row + x + 1]) - Double(patch[row + x]))
                        gradSum += dx
                    }
                    if y + 1 < 8 {
                        let dy = abs(Double(patch[row + 8 + x]) - Double(patch[row + x]))
                        gradSum += dy
                    }
                }
            }
            weightedGradient += weights[c] * (gradSum / 112.0)
        }

        let activity = sqrt(weightedVariance / 1.5) + 0.5 * (weightedGradient / 1.5)
        if activity <= 1e-7 {
            return 5
        }
        let targetMax = min(48.0, max(6.0, (24.0 / max(Double(distance), 0.5)).rounded()))
        let normalised = min(1.0, max(0.0, activity / 0.25))
        let qf = (5.0 + normalised * (targetMax - 5.0)).rounded()
        return Int32(min(targetMax, max(5.0, qf)))
    }
}
