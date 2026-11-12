// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Forward multi-block VarDCT analysis transforms (`16x16`..`64x64` and rectangular shapes)
/// and LLF (`Lowest-frequency`) DC extraction per ISO/IEC 18181-1 §10.2–10.3.
package struct VarDCTLargeAnalysis: Sendable {
    package struct Result: Sendable {
        package let coefficients: [Float]
        package let dc: [Float]
    }

    package struct Workspace {
        let budget: ScalarOperationBudget
        let capacity: Int
        var dctScratch: ScaledDCT.Workspace
        var coefficients: [Float]
        var dc: [Float]

        package init(capacity: Int = 4096, budget: ScalarOperationBudget) throws {
            try budget.checkpoint()
            guard capacity >= 64, capacity % 64 == 0 else {
                throw VarDCTError.invalidTransform
            }
            self.budget = budget
            self.capacity = capacity
            self.dctScratch = try ScaledDCT.Workspace(capacity: capacity, budget: budget)
            let dcCapacity = capacity / 64
            try budget.reserveWorkspace((capacity + dcCapacity) * MemoryLayout<Float>.stride)
            self.coefficients = [Float](repeating: 0, count: capacity)
            self.dc = [Float](repeating: 0, count: dcCapacity)
        }

        package func coefficient(at index: Int) -> Float {
            coefficients[index]
        }

        package func dcValue(at index: Int) -> Float {
            dc[index]
        }
    }

    package let identifier: Int
    package let rows: Int
    package let columns: Int
    let budget: ScalarOperationBudget
    private let dct: ScaledDCT
    private let sx: [Double]
    private let sy: [Double]
    private let cosX: [Double]
    private let cosY: [Double]

    private static let llfScales: [Int: [Double]] = [
        1: [1.0],
        2: [1.0, 1.108937353592731823],
        4: [1.0, 1.025760096781116015, 1.108937353592731823, 1.270559368765487251],
        8: [
            1.0, 1.0063534990068217, 1.0257600967811158, 1.0593017296817173,
            1.1089373535927318, 1.1777765381970435, 1.2705593687654873, 1.3944898413647777
        ]
    ]

    private static let llfCosTables: [Int: [Double]] = {
        var dict: [Int: [Double]] = [:]
        for cells in [1, 2, 4, 8] {
            var c = [Double](repeating: 0, count: cells * cells)
            for pos in 0..<cells {
                for freq in 0..<cells {
                    c[pos * cells + freq] = cos((Double(pos) + 0.5) * Double(freq) * .pi / Double(cells))
                }
            }
            dict[cells] = c
        }
        return dict
    }()

    package static func dimensions(for identifier: Int) -> (rows: Int, columns: Int)? {
        switch identifier {
        case 4:  return (16, 16)
        case 5:  return (32, 32)
        case 6:  return (16, 8)
        case 7:  return (8, 16)
        case 8:  return (32, 8)
        case 9:  return (8, 32)
        case 10: return (32, 16)
        case 11: return (16, 32)
        case 18: return (64, 64)
        case 19: return (64, 32)
        case 20: return (32, 64)
        default: return nil
        }
    }

    package init(identifier: Int, budget: ScalarOperationBudget) throws {
        var axes = ScaledDCT.AxisBank(direction: .forward, budget: budget)
        try self.init(identifier: identifier, budget: budget, axes: &axes)
    }

    package init(identifier: Int, budget: ScalarOperationBudget, axes: inout ScaledDCT.AxisBank) throws {
        try budget.checkpoint()
        guard let shape = Self.dimensions(for: identifier) else {
            throw VarDCTError.unsupportedStrategy(identifier)
        }
        self.identifier = identifier
        self.rows = shape.rows
        self.columns = shape.columns
        self.budget = budget
        self.dct = try ScaledDCT(
            rows: shape.rows,
            columns: shape.columns,
            direction: .forward,
            budget: budget,
            axes: &axes
        )

        let cellsX = shape.columns / 8
        let cellsY = shape.rows / 8
        guard let scalesX = Self.llfScales[cellsX], let scalesY = Self.llfScales[cellsY],
              let cx = Self.llfCosTables[cellsX], let cy = Self.llfCosTables[cellsY] else {
            throw VarDCTError.unsupportedStrategy(identifier)
        }
        self.sx = scalesX
        self.sy = scalesY
        self.cosX = cx
        self.cosY = cy
    }

    package func apply(_ pixels: [Float]) throws -> Result {
        let count = rows * columns
        var workspace = try Workspace(capacity: count, budget: budget)
        try pixels.withUnsafeBufferPointer { buf in
            try apply(buf, workspace: &workspace)
        }
        return Result(
            coefficients: Array(workspace.coefficients.prefix(count)),
            dc: Array(workspace.dc.prefix(count / 64))
        )
    }

    package func apply(_ pixels: UnsafeBufferPointer<Float>, workspace: inout Workspace) throws {
        try budget.checkpoint()
        let count = rows * columns
        guard workspace.budget === budget, workspace.capacity >= count, pixels.count == count else {
            throw VarDCTError.invalidTransform
        }
        for i in 0..<count {
            guard pixels[i].isFinite else {
                throw VarDCTError.nonFiniteSample
            }
        }

        try dct.apply(pixels, workspace: &workspace.dctScratch)

        let transpose = rows >= columns
        for y in 0..<rows {
            let rowBase = y * columns
            for x in 0..<columns {
                let target = transpose ? (x * rows + y) : (rowBase + x)
                workspace.coefficients[target] = workspace.dctScratch.value(at: rowBase + x)
            }
        }

        let cellsX = columns / 8
        let cellsY = rows / 8
        let root2 = 2.0.squareRoot()
        for y in 0..<cellsY {
            let cyBase = y * cellsY
            for x in 0..<cellsX {
                let cxBase = x * cellsX
                var sum = 0.0
                for v in 0..<cellsY {
                    let vRow = v * columns
                    let normV = v == 0 ? 1.0 : root2
                    let syV = sy[v]
                    let cosYV = cosY[cyBase + v]
                    for u in 0..<cellsX {
                        let value = Double(workspace.dctScratch.value(at: vRow + u)) / (sx[u] * syV)
                        let normalisation = (u == 0 ? 1.0 : root2) * normV
                        sum += value * normalisation * cosX[cxBase + u] * cosYV
                    }
                }
                workspace.dc[y * cellsX + x] = Float(sum)
            }
        }
    }

    /// Fast unchecked multi-block analysis for callers that have already validated finiteness and budgets.
    package func applyUnchecked(_ pixels: UnsafePointer<Float>, workspace: inout Workspace) {
        applyDCTAndDCUnchecked(pixels, workspace: &workspace)
        transposeCoefficientsUnchecked(workspace: &workspace)
    }

    /// Runs the 2D forward DCT and extracts LLF DC values without transposing AC coefficients yet.
    @inline(__always)
    package func applyDCTAndDCUnchecked(_ pixels: UnsafePointer<Float>, workspace: inout Workspace) {
        let r = rows
        let c = columns
        let cellsX = c >> 3
        let cellsY = r >> 3
        let root2 = 2.0.squareRoot()

        workspace.dctScratch.withMutablePointers { dctOut, inter in
            ScaledDCT.applyUnchecked(
                rows: r,
                columns: c,
                direction: .forward,
                input: pixels,
                output: dctOut,
                scratch: inter
            )

            workspace.dc.withUnsafeMutableBufferPointer { dcBuf in
                sx.withUnsafeBufferPointer { sxBuf in
                    sy.withUnsafeBufferPointer { syBuf in
                        cosX.withUnsafeBufferPointer { cxBuf in
                            cosY.withUnsafeBufferPointer { cyBuf in
                                let dcPtr = dcBuf.baseAddress!
                                let sxPtr = sxBuf.baseAddress!
                                let syPtr = syBuf.baseAddress!
                                let cxPtr = cxBuf.baseAddress!
                                let cyPtr = cyBuf.baseAddress!

                                withUnsafeTemporaryAllocation(of: Double.self, capacity: 64) { sfBuf in
                                    let sf = sfBuf.baseAddress!
                                    for v in 0..<cellsY {
                                        let vRow = v * c
                                        let normV = v == 0 ? 1.0 : root2
                                        let syV = syPtr[v]
                                        let sfRow = v * cellsX
                                        for u in 0..<cellsX {
                                            let value = Double(dctOut[vRow + u]) / (sxPtr[u] * syV)
                                            let normalisation = (u == 0 ? 1.0 : root2) * normV
                                            sf[sfRow + u] = value * normalisation
                                        }
                                    }
                                    for y in 0..<cellsY {
                                        let cyBase = y * cellsY
                                        for x in 0..<cellsX {
                                            let cxBase = x * cellsX
                                            var sum = 0.0
                                            for v in 0..<cellsY {
                                                let cosYV = cyPtr[cyBase + v]
                                                let sfRow = v * cellsX
                                                for u in 0..<cellsX {
                                                    sum += sf[sfRow + u] * cxPtr[cxBase + u] * cosYV
                                                }
                                            }
                                            dcPtr[y * cellsX + x] = Float(sum)
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

    /// Transposes or copies the most recent `dctScratch` output into `workspace.coefficients`.
    @inline(__always)
    package func transposeCoefficientsUnchecked(workspace: inout Workspace) {
        let r = rows
        let c = columns
        workspace.dctScratch.withMutablePointers { dctOut, _ in
            workspace.coefficients.withUnsafeMutableBufferPointer { coeffBuf in
                let coeffPtr = coeffBuf.baseAddress!
                if r >= c {
                    for y in 0..<r {
                        let rowBase = y * c
                        for x in 0..<c {
                            coeffPtr[x * r + y] = dctOut[rowBase + x]
                        }
                    }
                } else {
                    coeffPtr.update(from: dctOut, count: r * c)
                }
            }
        }
    }
}
