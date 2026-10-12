// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Codec/VarDCTEncoder.swift and LowestFrequenciesFromDC
// at 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause; see libjxl-LICENSE.txt.
import Foundation

/// Forward square/rectangular DCT and DC-plane extraction through 64×64.
/// The coefficient array uses codestream orientation; DC uses pixel-cell order.
package struct VarDCTLargeAnalysis: Sendable {
    package let identifier: Int, rows: Int, columns: Int
    private let budget: ScalarOperationBudget
    private let plan: ScaledDCT
    package init(identifier: Int, budget: ScalarOperationBudget) throws {
        let dimensions: [Int: (Int,Int)] = [4:(16,16),5:(32,32),6:(16,8),7:(8,16),
            8:(32,8),9:(8,32),10:(32,16),11:(16,32),18:(64,64),19:(64,32),20:(32,64)]
        guard let shape = dimensions[identifier] else { throw VarDCTError.unsupportedStrategy(identifier) }
        self.identifier = identifier; rows = shape.0; columns = shape.1; self.budget = budget
        plan = try ScaledDCT(rows: shape.0, columns: shape.1, direction: .forward, budget: budget)
    }
    package func apply(_ pixels: [Float]) throws -> (dc: [Float], coefficients: [Float]) {
        try budget.checkpoint()
        guard pixels.count == rows * columns else { throw VarDCTError.invalidTransform }
        let cellsY = rows / 8, cellsX = columns / 8
        try budget.reserveWorkspace((rows * columns + cellsY * cellsX) * MemoryLayout<Float>.stride)
        let ordinary = try plan.apply(pixels)
        var coefficients = [Float](repeating: 0, count: ordinary.count)
        for y in 0..<rows { for x in 0..<columns {
            coefficients[rows >= columns ? x * rows + y : y * columns + x] = ordinary[y * columns + x]
        } }
        let scales: [Int: [Double]] = [1:[1],2:[1,1.108937353592731823],
            4:[1,1.025760096781116015,1.108937353592731823,1.270559368765487251],
            8:[1,1.0063534990068217,1.0257600967811158,1.0593017296817173,
                1.1089373535927318,1.1777765381970435,1.2705593687654873,1.3944898413647777]]
        guard let sx = scales[cellsX], let sy = scales[cellsY] else { throw VarDCTError.invalidTransform }
        var dc = [Float](repeating: 0, count: cellsX * cellsY)
        for y in 0..<cellsY { for x in 0..<cellsX {
            try budget.checkpoint()
            var sum: Double = 0
            for v in 0..<cellsY { for u in 0..<cellsX {
                let value = Double(ordinary[v * columns + u]) / (sx[u] * sy[v])
                let normalisation = (u == 0 ? 1 : sqrt(2)) * (v == 0 ? 1 : sqrt(2))
                sum += value * normalisation * cos((Double(x) + 0.5) * Double(u) * .pi / Double(cellsX))
                    * cos((Double(y) + 0.5) * Double(v) * .pi / Double(cellsY))
            } }
            let value = Float(sum)
            guard value.isFinite else { throw VarDCTError.nonFiniteSample }
            dc[y * cellsX + x] = value
        } }
        return (dc,coefficients)
    }
}
