// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift VarDCT/{QuantWeights,AdjustQuantBias,AdaptiveDCSmoothing}.swift
// and Codec/JXLDecoder.swift at 57e81cb9e2411d1efac435b429a306a031744c1e.
// Copyright (c) 2026 Raster-Lab. JPEG XL Project Authors retain BSD-3-Clause.
import Foundation

/// DCT default-matrix reconstruction into admitted algorithm planes, not a
/// final image or public capability. No successful pixels are published here.
package enum VarDCTReconstruction {
    package static func xyb(_ coefficients: VarDCTCoefficients) throws -> [[Float]] {
        let e = coefficients.envelope, budget = e.budget
        if let unsupported = coefficients.strategies.transforms.first(where: { !VarDCTQuantWeights.supports($0.identifier) }) {
            throw VarDCTError.unsupportedStrategy(unsupported.identifier)
        }
        guard !e.frame.loopFilter.hasCustomParameters else {
            throw ScalarModularError.unsupportedProfile
        }
        let bx = coefficients.blocksX, by = coefficients.blocksY, blocks = bx * by
        let width = bx * 8, height = by * 8, samples = width * height
        try budget.reserveWorkspace(ScalarOperationBudget.product(samples + blocks * 2, 3 * 4))
        let invGlobal = Float(65536) / Float(coefficients.globalScale)
        let factors: [Float] = [4096, 512, 256].map { invGlobal / Float(coefficients.quantDC) / $0 }
        let extra = 1 / Float(1 << coefficients.dcExtraPrecision)
        let dcX = coefficients.baseX + Float(coefficients.dcX) / Float(coefficients.colourFactor)
        let dcB = coefficients.baseB + Float(coefficients.dcB) / Float(coefficients.colourFactor)
        var dc = (0..<3).map { _ in [Float](repeating: 0, count: blocks) }
        for i in 0..<blocks {
            if i & 255 == 0 { try budget.checkpoint() }
            let y = Float(coefficients.dc[1][i]) * factors[1] * extra
            dc[0][i] = Float(coefficients.dc[0][i]) * factors[0] * extra + dcX * y
            dc[1][i] = y
            dc[2][i] = Float(coefficients.dc[2][i]) * factors[2] * extra + dcB * y
        }
        if e.frame.flags & 128 == 0 { try smoothDC(&dc, width: bx, height: by, factors: factors, budget: budget) }
        try budget.reserveWorkspace(4096) // bounded small vectors
        let dm: [Float] = [powf(0.8, Float(e.frame.xQmScale) - 2), 1, powf(0.8, Float(e.frame.bQmScale) - 2)]
        var planes = (0..<3).map { _ in [Float](repeating: 0, count: samples) }
        let tilesX = (bx + 7) / 8
        for strategy in coefficients.strategies.transforms {
            try budget.checkpoint()
            let x = strategy.x, y = strategy.y, tile = (y / 8) * tilesX + x / 8
            let rows = strategy.cellsY * 8, columns = strategy.cellsX * 8, size = rows * columns
            let codedRows = min(rows, columns), codedColumns = max(rows, columns)
            let isAFV = (14...17).contains(strategy.identifier)
            let isSmall = [1,2,3,12,13].contains(strategy.identifier)
            let transpose = !isAFV && !isSmall && rows >= columns
            let weights = try VarDCTQuantWeights.make(identifier: strategy.identifier,
                rows: codedRows, columns: codedColumns, budget: budget)
            let transform = try ScaledDCT(rows: rows, columns: columns, direction: .inverse, budget: budget)
            try budget.reserveWorkspace(size * 3 * 4 + strategy.coveredCells * 3 * 4)
            var block = (0..<3).map { _ in [Float](repeating: 0, count: size) }
            let acX = coefficients.baseX + Float(coefficients.xSlopes[tile]) / Float(coefficients.colourFactor)
            let acB = coefficients.baseB + Float(coefficients.bSlopes[tile]) / Float(coefficients.colourFactor)
            let invQuant = invGlobal / Float(strategy.quantisation)
            // LLF coefficients are a forward transform of the covered DC cells,
            // resampled into the full transform's low-frequency corner.
            for c in 0..<3 {
                let low = try lowFrequencies(dc[c], stride: bx, strategy: strategy, budget: budget)
                for yy in 0..<strategy.cellsY { for xx in 0..<strategy.cellsX {
                    block[c][yy * columns + xx] = low[yy * strategy.cellsX + xx]
                } }
            }
            for k in 0..<size {
                if k & 255 == 0 { try budget.checkpoint() }
                let row = k / codedColumns, column = k % codedColumns
                if row < codedRows / 8, column < codedColumns / 8 { continue }
                let to = transpose ? column * columns + row : k
                let from = strategy.coefficientOffset + k
                let luma = adjust(coefficients.ac[1][from], channel: 1) / weights[size + k] * invQuant
                block[1][to] = luma
                block[0][to] = adjust(coefficients.ac[0][from], channel: 0) / weights[k] * invQuant * dm[0] + acX * luma
                block[2][to] = adjust(coefficients.ac[2][from], channel: 2) / weights[2 * size + k] * invQuant * dm[2] + acB * luma
            }
            for c in 0..<3 {
                let pixels: [Float]
                if isAFV { pixels = try VarDCTAFV.inverse(block[c], kind: strategy.identifier - 14, budget: budget) }
                else if isSmall { pixels = try VarDCTSmallTransforms.inverse(block[c], identifier: strategy.identifier, budget: budget) }
                else { pixels = try transform.apply(block[c]) }
                for row in 0..<rows {
                    try budget.checkpoint()
                    for column in 0..<columns {
                        planes[c][(y * 8 + row) * width + x * 8 + column] = pixels[row * columns + column]
                    }
                }
            }
        }
        if e.frame.loopFilter.gab {
            for c in 0..<3 {
                planes[c] = try Gaborish.apply(planes[c], width: e.width, height: e.height, stride: width, budget: budget)
            }
        } else if width != e.width || height != e.height {
            try budget.reserveWorkspace(e.width * e.height * 3 * 4)
            for c in 0..<3 {
                var tight = [Float](repeating: 0, count: e.width * e.height)
                for y in 0..<e.height {
                    try budget.checkpoint()
                    for x in 0..<e.width { tight[y * e.width + x] = planes[c][y * width + x] }
                }
                planes[c] = tight
            }
        }
        if e.frame.loopFilter.epfIters > 0 {
            planes = try EdgePreservingFilter.apply(planes, width: e.width, height: e.height,
                iterations: Int(e.frame.loopFilter.epfIters), quantisation: coefficients.quantFields,
                sharpness: coefficients.sharpness, globalScale: coefficients.globalScale, budget: budget)
        }
        try budget.checkpoint()
        return planes
    }

    private static func adjust(_ value: Int32, channel: Int) -> Float {
        // Avoid abs/negation of Int32.min inherited from the predecessor.
        if value == 0 { return 0 }
        let bias: [Float] = [1 - 0.05465007330715401, 1 - 0.07005449891748593, 1 - 0.049935103337343655]
        if value == 1 { return bias[channel] }
        if value == -1 { return -bias[channel] }
        let q = Float(value)
        return q - 0.145 / q
    }
    private static func lowFrequencies(_ dc: [Float], stride: Int,
                                       strategy: VarDCTStrategyMap.Transform,
                                       budget: ScalarOperationBudget) throws -> [Float] {
        let rows = strategy.cellsY, columns = strategy.cellsX
        guard rows <= 8, columns <= 8 else { throw VarDCTError.unsupportedStrategy(strategy.identifier) }
        try budget.reserveWorkspace(rows * columns * 4)
        if rows == 1, columns == 1 { return [dc[strategy.y * stride + strategy.x]] }
        // Scales are DCTResampleScales<N,8*N> from the pinned predecessor's
        // LowestFrequenciesFromDC (libjxl dct_scales.h).
        let scales: [Int: [Double]] = [
            1: [1], 2: [1, 1.108937353592731823],
            4: [1, 1.025760096781116015, 1.108937353592731823, 1.270559368765487251],
            8: [1, 1.0063534990068217, 1.0257600967811158, 1.0593017296817173,
                1.1089373535927318, 1.1777765381970435, 1.2705593687654873, 1.3944898413647777]
        ]
        guard let sx = scales[columns], let sy = scales[rows] else { throw VarDCTError.invalidTransform }
        var output = [Float](repeating: 0, count: rows * columns)
        for v in 0..<rows { for u in 0..<columns {
            try budget.checkpoint()
            var sum: Double = 0
            for y in 0..<rows { for x in 0..<columns {
                let sample = Double(dc[(strategy.y + y) * stride + strategy.x + x])
                sum += sample * cos((Double(x) + 0.5) * Double(u) * .pi / Double(columns))
                              * cos((Double(y) + 0.5) * Double(v) * .pi / Double(rows))
            } }
            let factor = (u == 0 ? 1 : sqrt(2)) * (v == 0 ? 1 : sqrt(2)) / Double(rows * columns)
            let value = Float(sum * factor * sx[u] * sy[v])
            guard value.isFinite else { throw VarDCTError.nonFiniteSample }
            output[v * columns + u] = value
        } }
        return output
    }
    private static func smoothDC(_ planes: inout [[Float]], width: Int, height: Int,
                                 factors: [Float], budget: ScalarOperationBudget) throws {
        guard width > 2, height > 2 else { return }
        try budget.reserveWorkspace(width * height * 3 * 4)
        var result = planes
        let w1: Float = 0.20345139757231578, w2: Float = 0.0334829185968739
        let w0: Float = 1 - 4 * (w1 + w2)
        var smoothed: [Float] = [0, 0, 0]
        for y in 1..<(height - 1) { for x in 1..<(width - 1) {
            if x & 255 == 1 { try budget.checkpoint() }
            let index = y * width + x
            var gap: Float = 0.5
            for c in 0..<3 {
                let p = planes[c]
                let corner = (p[index - width - 1] + p[index - width + 1]) + (p[index + width - 1] + p[index + width + 1])
                let side = (p[index - 1] + p[index + 1]) + (p[index - width] + p[index + width])
                let s = corner * w2 + side * w1 + p[index] * w0
                guard s.isFinite else { throw VarDCTError.nonFiniteSample }
                smoothed[c] = s; gap = max(gap, abs((p[index] - s) / factors[c]))
            }
            let factor = max(0, 3 - 4 * gap)
            for c in 0..<3 { result[c][index] = planes[c][index] + (smoothed[c] - planes[c][index]) * factor }
        } }
        planes = result
    }
}
