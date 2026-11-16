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

        @inline(__always)
        package mutating func withFastPointers<R>(
            _ body: (UnsafeMutablePointer<Double>, UnsafeMutablePointer<Float>) throws -> R
        ) rethrows -> R {
            try intermediate.withUnsafeMutableBufferPointer { interBuf in
                try values.withUnsafeMutableBufferPointer { valBuf in
                    try body(interBuf.baseAddress!, valBuf.baseAddress!)
                }
            }
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

                    // 1. Horizontal transform along each row (4-row batched when hStep >= 4 and r >= 4).
                    if r >= 4 && hStep >= 4 {
                        var y = 0
                        while y + 4 <= r {
                            if y % hStep == 0 {
                                try budget.checkpoint()
                            }
                            let ro0 = y &* c
                            let ro1 = ro0 &+ c
                            let ro2 = ro1 &+ c
                            let ro3 = ro2 &+ c
                            for u in 0..<c {
                                let wOffset = u &* c
                                var sum0: Double = 0
                                var sum1: Double = 0
                                var sum2: Double = 0
                                var sum3: Double = 0
                                for x in 0..<c {
                                    let w = colMat[wOffset &+ x]
                                    sum0 += Double(inBase[ro0 &+ x]) * w
                                    sum1 += Double(inBase[ro1 &+ x]) * w
                                    sum2 += Double(inBase[ro2 &+ x]) * w
                                    sum3 += Double(inBase[ro3 &+ x]) * w
                                }
                                inter[ro0 &+ u] = sum0
                                inter[ro1 &+ u] = sum1
                                inter[ro2 &+ u] = sum2
                                inter[ro3 &+ u] = sum3
                            }
                            y &+= 4
                        }
                        while y < r {
                            if y % hStep == 0 {
                                try budget.checkpoint()
                            }
                            let rowOffset = y &* c
                            for u in 0..<c {
                                let wOffset = u &* c
                                var sum: Double = 0
                                for x in 0..<c {
                                    sum += Double(inBase[rowOffset &+ x]) * colMat[wOffset &+ x]
                                }
                                inter[rowOffset &+ u] = sum
                            }
                            y &+= 1
                        }
                    } else {
                        for y in 0..<r {
                            if y % hStep == 0 {
                                try budget.checkpoint()
                            }
                            let rowOffset = y &* c
                            for u in 0..<c {
                                let wOffset = u &* c
                                var sum: Double = 0
                                for x in 0..<c {
                                    sum += Double(inBase[rowOffset &+ x]) * colMat[wOffset &+ x]
                                }
                                inter[rowOffset &+ u] = sum
                            }
                        }
                    }

                    // 2. Vertical transform along columns (4-column SIMD batched when c >= 4).
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
                                    let wOffset = v &* r
                                    var s0: Double = 0
                                    var s1: Double = 0
                                    var s2: Double = 0
                                    var s3: Double = 0
                                    for y in 0..<r {
                                        let w = rowMat[wOffset &+ y]
                                        let base = y &* c &+ x
                                        s0 += inter[base] * w
                                        s1 += inter[base &+ 1] * w
                                        s2 += inter[base &+ 2] * w
                                        s3 += inter[base &+ 3] * w
                                    }
                                    let dstBase = v &* c &+ x
                                    out[dstBase] = Float(s0)
                                    out[dstBase &+ 1] = Float(s1)
                                    out[dstBase &+ 2] = Float(s2)
                                    out[dstBase &+ 3] = Float(s3)
                                }
                                x &+= 4
                            }
                        } else {
                            let vSingleStep = max(1, 4096 / (r * r))
                            for x in 0..<c {
                                if x % vSingleStep == 0 {
                                    try budget.checkpoint()
                                }
                                for v in 0..<r {
                                    let wOffset = v &* r
                                    var sum: Double = 0
                                    for y in 0..<r {
                                        sum += inter[y &* c &+ x] * rowMat[wOffset &+ y]
                                    }
                                    out[v &* c &+ x] = Float(sum)
                                }
                            }
                        }
                    }
                }
            }
        }

        try budget.checkpoint()
        if workspace.values.count == count && workspace.staging.count == count {
            swap(&workspace.values, &workspace.staging)
        } else {
            for i in 0..<count {
                workspace.values[i] = workspace.staging[i]
            }
        }
    }

    /// Fast internal separable DCT over pre-validated finite input with caller-managed checkpoints.
    /// Produces IEEE-754 bit-identical output to `apply(_:workspace:)`.
    @inline(__always)
    package func applyFast(
        _ inBase: UnsafePointer<Float>,
        into out: UnsafeMutablePointer<Float>,
        inter: UnsafeMutablePointer<Double>
    ) {
        let r = rows
        let c = columns
        columnMatrix.withUnsafeBufferPointer { colMatBuf in
            rowMatrix.withUnsafeBufferPointer { rowMatBuf in
                let colMat = colMatBuf.baseAddress!
                let rowMat = rowMatBuf.baseAddress!

                if r >= 4 {
                    var y = 0
                    while y + 4 <= r {
                        let ro0 = y &* c
                        let ro1 = ro0 &+ c
                        let ro2 = ro1 &+ c
                        let ro3 = ro2 &+ c
                        for u in 0..<c {
                            let wOffset = u &* c
                            var sum0: Double = 0
                            var sum1: Double = 0
                            var sum2: Double = 0
                            var sum3: Double = 0
                            for x in 0..<c {
                                let w = colMat[wOffset &+ x]
                                sum0 += Double(inBase[ro0 &+ x]) * w
                                sum1 += Double(inBase[ro1 &+ x]) * w
                                sum2 += Double(inBase[ro2 &+ x]) * w
                                sum3 += Double(inBase[ro3 &+ x]) * w
                            }
                            inter[ro0 &+ u] = sum0
                            inter[ro1 &+ u] = sum1
                            inter[ro2 &+ u] = sum2
                            inter[ro3 &+ u] = sum3
                        }
                        y &+= 4
                    }
                    while y < r {
                        let rowOffset = y &* c
                        for u in 0..<c {
                            let wOffset = u &* c
                            var sum: Double = 0
                            for x in 0..<c {
                                sum += Double(inBase[rowOffset &+ x]) * colMat[wOffset &+ x]
                            }
                            inter[rowOffset &+ u] = sum
                        }
                        y &+= 1
                    }
                } else {
                    for y in 0..<r {
                        let rowOffset = y &* c
                        for u in 0..<c {
                            let wOffset = u &* c
                            var sum: Double = 0
                            for x in 0..<c {
                                sum += Double(inBase[rowOffset &+ x]) * colMat[wOffset &+ x]
                            }
                            inter[rowOffset &+ u] = sum
                        }
                    }
                }

                if c >= 4 {
                    let interRaw = UnsafeRawPointer(inter)
                    var x = 0
                    while x < c {
                        for v in 0..<r {
                            let wOffset = v &* r
                            var sVec = SIMD4<Double>.zero
                            for y in 0..<r {
                                let w = rowMat[wOffset &+ y]
                                let rowVec = interRaw.loadUnaligned(
                                    fromByteOffset: (y &* c &+ x) &* 8,
                                    as: SIMD4<Double>.self
                                )
                                sVec += rowVec * w
                            }
                            let dstBase = v &* c &+ x
                            out[dstBase] = Float(sVec[0])
                            out[dstBase &+ 1] = Float(sVec[1])
                            out[dstBase &+ 2] = Float(sVec[2])
                            out[dstBase &+ 3] = Float(sVec[3])
                        }
                        x &+= 4
                    }
                } else {
                    for x in 0..<c {
                        for v in 0..<r {
                            let wOffset = v &* r
                            var sum: Double = 0
                            for y in 0..<r {
                                sum += inter[y &* c &+ x] * rowMat[wOffset &+ y]
                            }
                            out[v &* c &+ x] = Float(sum)
                        }
                    }
                }
            }
        }
    }

    /// Specialized 8x8 forward DCT writing directly in transposed `[u * 8 + v]` layout (`id == 0`).
    /// Bit-identical to `apply` + transpose.
    @inline(__always)
    package func applyFastTransposed8x8(
        _ inBase: UnsafePointer<Float>,
        into outTransposed: UnsafeMutablePointer<Float>,
        inter: UnsafeMutablePointer<Double>
    ) {
        rowMatrix.withUnsafeBufferPointer { matBuf in
            let mat = matBuf.baseAddress!
            for yGrp in stride(from: 0, to: 8, by: 4) {
                let ro0 = yGrp &* 8
                let ro1 = ro0 &+ 8
                let ro2 = ro1 &+ 8
                let ro3 = ro2 &+ 8
                let d00 = Double(inBase[ro0]), d01 = Double(inBase[ro0 &+ 1]), d02 = Double(inBase[ro0 &+ 2]), d03 = Double(inBase[ro0 &+ 3])
                let d04 = Double(inBase[ro0 &+ 4]), d05 = Double(inBase[ro0 &+ 5]), d06 = Double(inBase[ro0 &+ 6]), d07 = Double(inBase[ro0 &+ 7])
                let d10 = Double(inBase[ro1]), d11 = Double(inBase[ro1 &+ 1]), d12 = Double(inBase[ro1 &+ 2]), d13 = Double(inBase[ro1 &+ 3])
                let d14 = Double(inBase[ro1 &+ 4]), d15 = Double(inBase[ro1 &+ 5]), d16 = Double(inBase[ro1 &+ 6]), d17 = Double(inBase[ro1 &+ 7])
                let d20 = Double(inBase[ro2]), d21 = Double(inBase[ro2 &+ 1]), d22 = Double(inBase[ro2 &+ 2]), d23 = Double(inBase[ro2 &+ 3])
                let d24 = Double(inBase[ro2 &+ 4]), d25 = Double(inBase[ro2 &+ 5]), d26 = Double(inBase[ro2 &+ 6]), d27 = Double(inBase[ro2 &+ 7])
                let d30 = Double(inBase[ro3]), d31 = Double(inBase[ro3 &+ 1]), d32 = Double(inBase[ro3 &+ 2]), d33 = Double(inBase[ro3 &+ 3])
                let d34 = Double(inBase[ro3 &+ 4]), d35 = Double(inBase[ro3 &+ 5]), d36 = Double(inBase[ro3 &+ 6]), d37 = Double(inBase[ro3 &+ 7])
                for u in 0..<8 {
                    let w = mat + (u &* 8)
                    let w0 = w[0], w1 = w[1], w2 = w[2], w3 = w[3], w4 = w[4], w5 = w[5], w6 = w[6], w7 = w[7]
                    let s0Lo: Double = ((d00 * w0 + d01 * w1) + d02 * w2) + d03 * w3
                    inter[ro0 &+ u] = (((s0Lo + d04 * w4) + d05 * w5) + d06 * w6) + d07 * w7
                    let s1Lo: Double = ((d10 * w0 + d11 * w1) + d12 * w2) + d13 * w3
                    inter[ro1 &+ u] = (((s1Lo + d14 * w4) + d15 * w5) + d16 * w6) + d17 * w7
                    let s2Lo: Double = ((d20 * w0 + d21 * w1) + d22 * w2) + d23 * w3
                    inter[ro2 &+ u] = (((s2Lo + d24 * w4) + d25 * w5) + d26 * w6) + d27 * w7
                    let s3Lo: Double = ((d30 * w0 + d31 * w1) + d32 * w2) + d33 * w3
                    inter[ro3 &+ u] = (((s3Lo + d34 * w4) + d35 * w5) + d36 * w6) + d37 * w7
                }
            }
            let interRaw = UnsafeRawPointer(inter)
            for x in [0, 4] {
                let r0 = interRaw.loadUnaligned(fromByteOffset: (0 &* 8 &+ x) &* 8, as: SIMD4<Double>.self)
                let r1 = interRaw.loadUnaligned(fromByteOffset: (1 &* 8 &+ x) &* 8, as: SIMD4<Double>.self)
                let r2 = interRaw.loadUnaligned(fromByteOffset: (2 &* 8 &+ x) &* 8, as: SIMD4<Double>.self)
                let r3 = interRaw.loadUnaligned(fromByteOffset: (3 &* 8 &+ x) &* 8, as: SIMD4<Double>.self)
                let r4 = interRaw.loadUnaligned(fromByteOffset: (4 &* 8 &+ x) &* 8, as: SIMD4<Double>.self)
                let r5 = interRaw.loadUnaligned(fromByteOffset: (5 &* 8 &+ x) &* 8, as: SIMD4<Double>.self)
                let r6 = interRaw.loadUnaligned(fromByteOffset: (6 &* 8 &+ x) &* 8, as: SIMD4<Double>.self)
                let r7 = interRaw.loadUnaligned(fromByteOffset: (7 &* 8 &+ x) &* 8, as: SIMD4<Double>.self)
                for v in 0..<8 {
                    let w = mat + (v &* 8)
                    let w0 = w[0], w1 = w[1], w2 = w[2], w3 = w[3]
                    let w4 = w[4], w5 = w[5], w6 = w[6], w7 = w[7]
                    let sVecLo: SIMD4<Double> = ((r0 * w0 + r1 * w1) + r2 * w2) + r3 * w3
                    let sVec: SIMD4<Double> = (((sVecLo + r4 * w4) + r5 * w5) + r6 * w6) + r7 * w7
                    outTransposed[(x &+ 0) &* 8 &+ v] = Float(sVec[0])
                    outTransposed[(x &+ 1) &* 8 &+ v] = Float(sVec[1])
                    outTransposed[(x &+ 2) &* 8 &+ v] = Float(sVec[2])
                    outTransposed[(x &+ 3) &* 8 &+ v] = Float(sVec[3])
                }
            }
        }
    }
}
