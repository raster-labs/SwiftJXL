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
    private let dcScaleProducts: [Double], dcNormalisations: [Double]
    private let dcHorizontal: [Double], dcVertical: [Double]
    package init(identifier: Int, budget: ScalarOperationBudget) throws {
        var axes = ScaledDCT.AxisBank(direction: .forward, budget: budget)
        try self.init(identifier: identifier, budget: budget, axes: &axes)
    }
    package init(identifier: Int, budget: ScalarOperationBudget, axes: inout ScaledDCT.AxisBank) throws {
        let dimensions: [Int: (Int,Int)] = [4:(16,16),5:(32,32),6:(16,8),7:(8,16),
            8:(32,8),9:(8,32),10:(32,16),11:(16,32),18:(64,64),19:(64,32),20:(32,64)]
        guard let shape = dimensions[identifier] else { throw VarDCTError.unsupportedStrategy(identifier) }
        self.identifier = identifier; rows = shape.0; columns = shape.1; self.budget = budget
        plan = try ScaledDCT(rows: shape.0, columns: shape.1, direction: .forward, budget: budget, axes: &axes)
        let cellsX = shape.1 / 8, cellsY = shape.0 / 8
        guard let sx = Self.dcScales[cellsX], let sy = Self.dcScales[cellsY] else { throw VarDCTError.invalidTransform }
        // Store the separate factors, never their reassociated product: each
        // application retains the reference division/multiplication order.
        try budget.reserveWorkspace((2 * cellsX * cellsY + cellsX * cellsX + cellsY * cellsY) * MemoryLayout<Double>.stride)
        var scales = [Double](repeating: 0, count: cellsX * cellsY)
        var normalisations = scales
        for v in 0..<cellsY { for u in 0..<cellsX {
            scales[v * cellsX + u] = sx[u] * sy[v]
            normalisations[v * cellsX + u] = (u == 0 ? 1 : sqrt(2)) * (v == 0 ? 1 : sqrt(2))
        } }
        var horizontal = [Double](repeating: 0, count: cellsX * cellsX)
        var vertical = [Double](repeating: 0, count: cellsY * cellsY)
        for x in 0..<cellsX { for u in 0..<cellsX {
            horizontal[x * cellsX + u] = cos((Double(x) + 0.5) * Double(u) * .pi / Double(cellsX))
        } }
        for y in 0..<cellsY { for v in 0..<cellsY {
            vertical[y * cellsY + v] = cos((Double(y) + 0.5) * Double(v) * .pi / Double(cellsY))
        } }
        dcScaleProducts = scales; dcNormalisations = normalisations
        dcHorizontal = horizontal; dcVertical = vertical
    }
    package struct Workspace: ~Copyable {
        fileprivate let budget: ScalarOperationBudget
        fileprivate let capacity: Int
        fileprivate var rows = 0, columns = 0
        fileprivate var dc: [Float]
        fileprivate var dct: ScaledDCT.Workspace
        package init(capacity: Int = 4096, budget: ScalarOperationBudget) throws {
            guard capacity >= 64, capacity <= 4096, capacity % 64 == 0 else { throw VarDCTError.invalidTransform }
            // Keep the original conservative admission; the coefficient view
            // now reuses DCT output rather than allocating a second owner.
            try budget.reserveWorkspace((capacity + capacity / 64) * MemoryLayout<Float>.stride)
            dct = try ScaledDCT.Workspace(capacity: capacity, budget: budget)
            self.budget = budget
            self.capacity = capacity
            dc = [Float](repeating: 0, count: capacity / 64)
        }
        /// Read only after a successful apply. Codestream orientation is a
        /// coordinate mapping into existing DCT output, requiring no copy.
        package func coefficient(at index: Int) -> Float {
            precondition(index >= 0 && index < rows * columns)
            return dct.value(at: rows >= columns ? (index % rows) * columns + index / rows : index)
        }
        package func dcValue(at index: Int) -> Float { dc[index] }
    }
    package func apply(_ pixels: [Float]) throws -> (dc: [Float], coefficients: [Float]) {
        guard pixels.count == rows * columns else { throw VarDCTError.invalidTransform }
        var workspace = try Workspace(capacity: pixels.count, budget: budget)
        try pixels.withUnsafeBufferPointer { try apply($0, workspace: &workspace) }
        try budget.reserveWorkspace((pixels.count + pixels.count / 64) * MemoryLayout<Float>.stride)
        return ((0..<(pixels.count / 64)).map { workspace.dcValue(at: $0) },
                (0..<pixels.count).map { workspace.coefficient(at: $0) })
    }
    /// Synchronous input borrow into exclusively owned reusable storage. The
    /// caller retains the input owner; no pointer or array storage escapes.
    package func apply(_ pixels: UnsafeBufferPointer<Float>, workspace: inout Workspace) throws {
        try budget.checkpoint()
        guard pixels.count == rows * columns, workspace.capacity >= pixels.count,
              workspace.budget === budget else { throw VarDCTError.invalidTransform }
        let cellsY = rows / 8, cellsX = columns / 8
        try plan.apply(pixels, workspace: &workspace.dct)
        try workspace.dct.withValues { values in
            try workspace.dc.withUnsafeMutableBufferPointer { dc in
                for y in 0..<cellsY { for x in 0..<cellsX {
                    try budget.checkpoint()
                    var sum: Double = 0
                    for v in 0..<cellsY { for u in 0..<cellsX {
                        let frequency = v * cellsX + u
                        let value = Double(values[v * columns + u]) / dcScaleProducts[frequency]
                        sum += value * dcNormalisations[frequency] * dcHorizontal[x * cellsX + u]
                            * dcVertical[y * cellsY + v]
                    } }
                    let value = Float(sum)
                    guard value.isFinite else { throw VarDCTError.nonFiniteSample }
                    dc[y * cellsX + x] = value
                } }
            }
        }
        workspace.rows = rows; workspace.columns = columns
    }
    private static let dcScales: [Int: [Double]] = [1:[1],2:[1,1.108937353592731823],
            4:[1,1.025760096781116015,1.108937353592731823,1.270559368765487251],
            8:[1,1.0063534990068217,1.0257600967811158,1.0593017296817173,
                1.1089373535927318,1.1777765381970435,1.2705593687654873,1.3944898413647777]]

}
