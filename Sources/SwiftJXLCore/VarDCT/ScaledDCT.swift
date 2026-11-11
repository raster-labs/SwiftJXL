// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Errors thrown by the VarDCT transform, reconstruction, and colour stages.
package enum VarDCTError: Error, Sendable, Equatable {
    case invalidTransform
    case nonFiniteSample
    case unsupportedStrategy(Int)
}

/// Orthonormal/scaled 2D separable Type-II (forward) and Type-III (inverse) DCT (ISO/IEC 18181-1 §§10.1–10.3).
package struct ScaledDCT: Sendable {
    package enum Direction: Sendable, Equatable {
        case forward
        case inverse
    }

    package struct AxisBank: Sendable {
        fileprivate let direction: Direction
        fileprivate let budget: ScalarOperationBudget
        fileprivate var matrices: [Int: [Double]] = [:]

        package init(direction: Direction, budget: ScalarOperationBudget) {
            self.direction = direction
            self.budget = budget
        }
    }

    package struct Workspace: Sendable {
        fileprivate let capacity: Int
        fileprivate let budget: ScalarOperationBudget
        fileprivate var intermediate: [Double]
        fileprivate var staging: [Float]
        fileprivate var values: [Float]

        package init(capacity: Int, budget: ScalarOperationBudget) throws {
            try budget.checkpoint()
            guard capacity > 0 else { throw VarDCTError.invalidTransform }
            let (doubleCap, over1) = capacity.multipliedReportingOverflow(by: 2)
            let (bytes, over2) = doubleCap.multipliedReportingOverflow(by: MemoryLayout<Float>.stride)
            guard !over1, !over2 else { throw VarDCTError.invalidTransform }
            try budget.reserveWorkspace(bytes)
            self.capacity = capacity
            self.budget = budget
            self.intermediate = [Double](repeating: 0, count: capacity)
            self.staging = [Float](repeating: 0, count: capacity)
            self.values = [Float](repeating: 0, count: capacity)
        }

        @inline(__always)
        package func value(at index: Int) -> Float {
            values[index]
        }

        @inline(__always)
        package func withValues<R>(_ body: (UnsafeBufferPointer<Float>) throws -> R) rethrows -> R {
            try values.withUnsafeBufferPointer(body)
        }
    }

    package static let supportedAxisSizes: Set<Int> = [2, 4, 8, 16, 32, 64]

    package let rows: Int
    package let columns: Int
    package let direction: Direction
    private let budget: ScalarOperationBudget
    private let rowMatrix: [Double]
    private let columnMatrix: [Double]

    private static func makeBasisMatrix(size n: Int, direction: Direction) -> [Double] {
        var matrix = [Double](repeating: 0, count: n * n)
        let denom = Double(2 * n)
        let scale = (direction == .inverse) ? 1.0 : Double(n)
        let sqrt2 = Double(2.0).squareRoot()
        for outIdx in 0..<n {
            for inIdx in 0..<n {
                let k = (direction == .inverse) ? inIdx : outIdx
                let t = (direction == .inverse) ? outIdx : inIdx
                let norm = (k == 0) ? 1.0 : sqrt2
                let angle = Double(2 * t + 1) * Double(k) * Double.pi / denom
                matrix[outIdx * n + inIdx] = (norm * cos(angle)) / scale
            }
        }
        return matrix
    }

    package init(
        rows: Int,
        columns: Int,
        direction: Direction,
        budget: ScalarOperationBudget
    ) throws {
        try budget.checkpoint()
        guard Self.supportedAxisSizes.contains(rows),
              Self.supportedAxisSizes.contains(columns) else {
            throw VarDCTError.invalidTransform
        }
        let basisBytes = (rows * rows + columns * columns) * MemoryLayout<Double>.stride
        try budget.reserveWorkspace(basisBytes)
        self.rows = rows
        self.columns = columns
        self.direction = direction
        self.budget = budget
        self.rowMatrix = Self.makeBasisMatrix(size: rows, direction: direction)
        self.columnMatrix = (rows == columns)
            ? self.rowMatrix
            : Self.makeBasisMatrix(size: columns, direction: direction)
    }

    package init(
        rows: Int,
        columns: Int,
        direction: Direction,
        budget: ScalarOperationBudget,
        axes: inout AxisBank
    ) throws {
        try budget.checkpoint()
        guard Self.supportedAxisSizes.contains(rows),
              Self.supportedAxisSizes.contains(columns),
              direction == axes.direction,
              budget === axes.budget else {
            throw VarDCTError.invalidTransform
        }
        let basisBytes = (rows * rows + columns * columns) * MemoryLayout<Double>.stride
        try budget.reserveWorkspace(basisBytes)
        self.rows = rows
        self.columns = columns
        self.direction = direction
        self.budget = budget

        if let existingRows = axes.matrices[rows] {
            self.rowMatrix = existingRows
        } else {
            let created = Self.makeBasisMatrix(size: rows, direction: direction)
            axes.matrices[rows] = created
            self.rowMatrix = created
        }

        if let existingCols = axes.matrices[columns] {
            self.columnMatrix = existingCols
        } else {
            let created = Self.makeBasisMatrix(size: columns, direction: direction)
            axes.matrices[columns] = created
            self.columnMatrix = created
        }
    }

    @inline(__always)
    private static func isValidSample(_ value: Float) -> Bool {
        value.isFinite && abs(value) < Float.greatestFiniteMagnitude
    }

    package func apply(_ input: [Float]) throws -> [Float] {
        try budget.checkpoint()
        guard input.count == rows * columns else {
            throw VarDCTError.invalidTransform
        }
        for v in input {
            if !Self.isValidSample(v) {
                throw VarDCTError.nonFiniteSample
            }
        }
        var workspace = try Workspace(capacity: rows * columns, budget: budget)
        try input.withUnsafeBufferPointer { ptr in
            try apply(ptr, workspace: &workspace)
        }
        return Array(workspace.values.prefix(rows * columns))
    }

    package func apply(
        _ input: UnsafeBufferPointer<Float>,
        workspace: inout Workspace
    ) throws {
        try budget.checkpoint()
        let count = rows * columns
        guard workspace.budget === budget,
              input.count == count,
              workspace.capacity >= count,
              let inBase = input.baseAddress else {
            throw VarDCTError.invalidTransform
        }

        for i in 0..<count {
            if !Self.isValidSample(inBase[i]) {
                throw VarDCTError.nonFiniteSample
            }
        }

        let r = rows
        let c = columns
        let hStep = max(1, 4096 / (c * c))

        try columnMatrix.withUnsafeBufferPointer { colMatBuf in
            try rowMatrix.withUnsafeBufferPointer { rowMatBuf in
                let colMat = colMatBuf.baseAddress!
                let rowMat = rowMatBuf.baseAddress!

                try workspace.intermediate.withUnsafeMutableBufferPointer { interBuf in
                    let inter = interBuf.baseAddress!

                    // 1. Horizontal transform along each row.
                    for y in 0..<r {
                        if y % hStep == 0 {
                            try budget.checkpoint()
                        }
                        let rowOffset = y * c
                        for u in 0..<c {
                            let wOffset = u * c
                            var sum: Double = 0
                            for x in 0..<c {
                                sum += Double(inBase[rowOffset + x]) * colMat[wOffset + x]
                            }
                            inter[rowOffset + u] = sum
                        }
                    }

                    // 2. Vertical transform along columns (4-column batched when columns >= 4).
                    try workspace.staging.withUnsafeMutableBufferPointer { stageBuf in
                        let out = stageBuf.baseAddress!
                        if c >= 4 {
                            let vBatchStep = max(4, 4096 / (r * r))
                            let vFreqStep = max(4, 4096 / (4 * r))
                            var x = 0
                            while x < c {
                                if x % vBatchStep == 0 {
                                    try budget.checkpoint()
                                }
                                for v in 0..<r {
                                    if v > 0 && v % vFreqStep == 0 {
                                        try budget.checkpoint()
                                    }
                                    let wOffset = v * r
                                    var s0: Double = 0
                                    var s1: Double = 0
                                    var s2: Double = 0
                                    var s3: Double = 0
                                    for y in 0..<r {
                                        let w = rowMat[wOffset + y]
                                        let base = y * c + x
                                        s0 += inter[base] * w
                                        s1 += inter[base + 1] * w
                                        s2 += inter[base + 2] * w
                                        s3 += inter[base + 3] * w
                                    }
                                    let dstBase = v * c + x
                                    out[dstBase] = Float(s0)
                                    out[dstBase + 1] = Float(s1)
                                    out[dstBase + 2] = Float(s2)
                                    out[dstBase + 3] = Float(s3)
                                }
                                x += 4
                            }
                        } else {
                            let vSingleStep = max(1, 4096 / (r * r))
                            for x in 0..<c {
                                if x % vSingleStep == 0 {
                                    try budget.checkpoint()
                                }
                                for v in 0..<r {
                                    let wOffset = v * r
                                    var sum: Double = 0
                                    for y in 0..<r {
                                        sum += inter[y * c + x] * rowMat[wOffset + y]
                                    }
                                    out[v * c + x] = Float(sum)
                                }
                            }
                        }
                    }
                }
            }
        }

        try budget.checkpoint()
        for i in 0..<count {
            workspace.values[i] = workspace.staging[i]
        }
    }
}
