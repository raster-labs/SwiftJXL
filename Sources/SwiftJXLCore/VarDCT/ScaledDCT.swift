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
        package mutating func withMutablePointers<R>(
            _ body: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Double>) throws -> R
        ) rethrows -> R {
            try values.withUnsafeMutableBufferPointer { valBuf in
                try intermediate.withUnsafeMutableBufferPointer { interBuf in
                    try body(valBuf.baseAddress!, interBuf.baseAddress!)
                }
            }
        }
    }

    package static let supportedAxisSizes: Set<Int> = [2, 4, 8, 16, 32, 64]

    private static let forward2 = makeBasisMatrix(size: 2, direction: .forward)
    private static let forward4 = makeBasisMatrix(size: 4, direction: .forward)
    private static let forward8 = makeBasisMatrix(size: 8, direction: .forward)
    private static let forward16 = makeBasisMatrix(size: 16, direction: .forward)
    private static let forward32 = makeBasisMatrix(size: 32, direction: .forward)
    private static let forward64 = makeBasisMatrix(size: 64, direction: .forward)

    private static let inverse2 = makeBasisMatrix(size: 2, direction: .inverse)
    private static let inverse4 = makeBasisMatrix(size: 4, direction: .inverse)
    private static let inverse8 = makeBasisMatrix(size: 8, direction: .inverse)
    private static let inverse16 = makeBasisMatrix(size: 16, direction: .inverse)
    private static let inverse32 = makeBasisMatrix(size: 32, direction: .inverse)
    private static let inverse64 = makeBasisMatrix(size: 64, direction: .inverse)

    private static func makeImmortalPointer(_ array: [Double]) -> UnsafePointer<Double> {
        let ptr = UnsafeMutablePointer<Double>.allocate(capacity: array.count)
        array.withUnsafeBufferPointer { buf in
            ptr.initialize(from: buf.baseAddress!, count: buf.count)
        }
        return UnsafePointer(ptr)
    }

    private static func makeSimdBasisMatrix(from matrix: [Double], size n: Int) -> [SIMD4<Double>] {
        let groups = (n + 3) / 4
        var result = [SIMD4<Double>](repeating: .zero, count: groups * n)
        for u in 0..<n {
            let group = u >> 2
            let lane = u & 3
            let srcRow = u * n
            let dstBase = group * n
            for x in 0..<n {
                result[dstBase + x][lane] = matrix[srcRow + x]
            }
        }
        return result
    }

    private static func makeImmortalSimdPointer(_ matrix: [Double], size n: Int) -> UnsafePointer<SIMD4<Double>> {
        let simd = makeSimdBasisMatrix(from: matrix, size: n)
        let ptr = UnsafeMutablePointer<SIMD4<Double>>.allocate(capacity: simd.count)
        simd.withUnsafeBufferPointer { buf in
            ptr.initialize(from: buf.baseAddress!, count: buf.count)
        }
        return UnsafePointer(ptr)
    }

    nonisolated(unsafe) private static let forwardPtr2 = makeImmortalPointer(forward2)
    nonisolated(unsafe) private static let forwardPtr4 = makeImmortalPointer(forward4)
    nonisolated(unsafe) private static let forwardPtr8 = makeImmortalPointer(forward8)
    nonisolated(unsafe) private static let forwardPtr16 = makeImmortalPointer(forward16)
    nonisolated(unsafe) private static let forwardPtr32 = makeImmortalPointer(forward32)
    nonisolated(unsafe) private static let forwardPtr64 = makeImmortalPointer(forward64)

    nonisolated(unsafe) private static let inversePtr2 = makeImmortalPointer(inverse2)
    nonisolated(unsafe) private static let inversePtr4 = makeImmortalPointer(inverse4)
    nonisolated(unsafe) private static let inversePtr8 = makeImmortalPointer(inverse8)
    nonisolated(unsafe) private static let inversePtr16 = makeImmortalPointer(inverse16)
    nonisolated(unsafe) private static let inversePtr32 = makeImmortalPointer(inverse32)
    nonisolated(unsafe) private static let inversePtr64 = makeImmortalPointer(inverse64)

    nonisolated(unsafe) private static let forwardSimdPtr2 = makeImmortalSimdPointer(forward2, size: 2)
    nonisolated(unsafe) private static let forwardSimdPtr4 = makeImmortalSimdPointer(forward4, size: 4)
    nonisolated(unsafe) private static let forwardSimdPtr8 = makeImmortalSimdPointer(forward8, size: 8)
    nonisolated(unsafe) private static let forwardSimdPtr16 = makeImmortalSimdPointer(forward16, size: 16)
    nonisolated(unsafe) private static let forwardSimdPtr32 = makeImmortalSimdPointer(forward32, size: 32)
    nonisolated(unsafe) private static let forwardSimdPtr64 = makeImmortalSimdPointer(forward64, size: 64)

    nonisolated(unsafe) private static let inverseSimdPtr2 = makeImmortalSimdPointer(inverse2, size: 2)
    nonisolated(unsafe) private static let inverseSimdPtr4 = makeImmortalSimdPointer(inverse4, size: 4)
    nonisolated(unsafe) private static let inverseSimdPtr8 = makeImmortalSimdPointer(inverse8, size: 8)
    nonisolated(unsafe) private static let inverseSimdPtr16 = makeImmortalSimdPointer(inverse16, size: 16)
    nonisolated(unsafe) private static let inverseSimdPtr32 = makeImmortalSimdPointer(inverse32, size: 32)
    nonisolated(unsafe) private static let inverseSimdPtr64 = makeImmortalSimdPointer(inverse64, size: 64)

    @inline(__always)
    package static func cachedSimdMatrixPointer(size n: Int, direction: Direction) -> UnsafePointer<SIMD4<Double>> {
        if direction == .forward {
            switch n {
            case 8: return forwardSimdPtr8
            case 4: return forwardSimdPtr4
            case 16: return forwardSimdPtr16
            case 32: return forwardSimdPtr32
            case 64: return forwardSimdPtr64
            default: return forwardSimdPtr2
            }
        } else {
            switch n {
            case 8: return inverseSimdPtr8
            case 4: return inverseSimdPtr4
            case 16: return inverseSimdPtr16
            case 32: return inverseSimdPtr32
            case 64: return inverseSimdPtr64
            default: return inverseSimdPtr2
            }
        }
    }

    @inline(__always)
    package static func cachedMatrix(size n: Int, direction: Direction) -> [Double] {
        if direction == .forward {
            switch n {
            case 8: return forward8
            case 4: return forward4
            case 16: return forward16
            case 32: return forward32
            case 64: return forward64
            default: return forward2
            }
        } else {
            switch n {
            case 8: return inverse8
            case 4: return inverse4
            case 16: return inverse16
            case 32: return inverse32
            case 64: return inverse64
            default: return inverse2
            }
        }
    }

    @inline(__always)
    package static func cachedMatrixPointer(size n: Int, direction: Direction) -> UnsafePointer<Double> {
        if direction == .forward {
            switch n {
            case 8: return forwardPtr8
            case 4: return forwardPtr4
            case 16: return forwardPtr16
            case 32: return forwardPtr32
            case 64: return forwardPtr64
            default: return forwardPtr2
            }
        } else {
            switch n {
            case 8: return inversePtr8
            case 4: return inversePtr4
            case 16: return inversePtr16
            case 32: return inversePtr32
            case 64: return inversePtr64
            default: return inversePtr2
            }
        }
    }

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
        self.rowMatrix = Self.cachedMatrix(size: rows, direction: direction)
        self.columnMatrix = (rows == columns)
            ? self.rowMatrix
            : Self.cachedMatrix(size: columns, direction: direction)
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
            let created = Self.cachedMatrix(size: rows, direction: direction)
            axes.matrices[rows] = created
            self.rowMatrix = created
        }

        if let existingCols = axes.matrices[columns] {
            self.columnMatrix = existingCols
        } else {
            let created = Self.cachedMatrix(size: columns, direction: direction)
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
                    try workspace.values.withUnsafeMutableBufferPointer { stageBuf in
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
    }

    /// Fast unchecked 2D separable DCT for internal callers that have already validated finiteness and budgets.
    @inline(__always)
    package static func applyUnchecked(
        rows r: Int,
        columns c: Int,
        direction: Direction,
        input inBase: UnsafePointer<Float>,
        output out: UnsafeMutablePointer<Float>,
        scratch inter: UnsafeMutablePointer<Double>
    ) {
        let vPtr = cachedSimdMatrixPointer(size: r, direction: direction)
        let hPtr = (r == c) ? vPtr : cachedSimdMatrixPointer(size: c, direction: direction)

        // 1. Horizontal pass (SIMD4<Double> across output frequencies, 2 rows per batch when r >= 2)
        if c == 8 {
            var y = 0
            while y + 1 < r {
                let r0 = y &* 8
                let r1 = r0 &+ 8
                var s0_0 = SIMD4<Double>(repeating: 0)
                var s0_1 = SIMD4<Double>(repeating: 0)
                var s1_0 = SIMD4<Double>(repeating: 0)
                var s1_1 = SIMD4<Double>(repeating: 0)
                for x in 0..<8 {
                    let w0 = hPtr[x]
                    let w1 = hPtr[8 &+ x]
                    let in0 = SIMD4<Double>(repeating: Double(inBase[r0 &+ x]))
                    let in1 = SIMD4<Double>(repeating: Double(inBase[r1 &+ x]))
                    s0_0 += w0 * in0
                    s0_1 += w1 * in0
                    s1_0 += w0 * in1
                    s1_1 += w1 * in1
                }
                inter[r0] = s0_0[0]; inter[r0 &+ 1] = s0_0[1]; inter[r0 &+ 2] = s0_0[2]; inter[r0 &+ 3] = s0_0[3]
                inter[r0 &+ 4] = s0_1[0]; inter[r0 &+ 5] = s0_1[1]; inter[r0 &+ 6] = s0_1[2]; inter[r0 &+ 7] = s0_1[3]
                inter[r1] = s1_0[0]; inter[r1 &+ 1] = s1_0[1]; inter[r1 &+ 2] = s1_0[2]; inter[r1 &+ 3] = s1_0[3]
                inter[r1 &+ 4] = s1_1[0]; inter[r1 &+ 5] = s1_1[1]; inter[r1 &+ 6] = s1_1[2]; inter[r1 &+ 7] = s1_1[3]
                y &+= 2
            }
        } else if c >= 16 {
            let uSteps = c &>> 4
            var y = 0
            while y + 1 < r {
                let r0 = y &* c
                let r1 = r0 &+ c
                for uStep in 0..<uSteps {
                    let u = uStep &* 16
                    let hBase0 = (uStep &* 4) &* c
                    let hBase1 = hBase0 &+ c
                    let hBase2 = hBase1 &+ c
                    let hBase3 = hBase2 &+ c
                    var s0_0 = SIMD4<Double>(repeating: 0)
                    var s0_1 = SIMD4<Double>(repeating: 0)
                    var s0_2 = SIMD4<Double>(repeating: 0)
                    var s0_3 = SIMD4<Double>(repeating: 0)
                    var s1_0 = SIMD4<Double>(repeating: 0)
                    var s1_1 = SIMD4<Double>(repeating: 0)
                    var s1_2 = SIMD4<Double>(repeating: 0)
                    var s1_3 = SIMD4<Double>(repeating: 0)
                    for x in 0..<c {
                        let w0 = hPtr[hBase0 &+ x]
                        let w1 = hPtr[hBase1 &+ x]
                        let w2 = hPtr[hBase2 &+ x]
                        let w3 = hPtr[hBase3 &+ x]
                        let in0 = SIMD4<Double>(repeating: Double(inBase[r0 &+ x]))
                        let in1 = SIMD4<Double>(repeating: Double(inBase[r1 &+ x]))
                        s0_0 += w0 * in0; s0_1 += w1 * in0; s0_2 += w2 * in0; s0_3 += w3 * in0
                        s1_0 += w0 * in1; s1_1 += w1 * in1; s1_2 += w2 * in1; s1_3 += w3 * in1
                    }
                    let o0 = r0 &+ u
                    inter[o0] = s0_0[0]; inter[o0 &+ 1] = s0_0[1]; inter[o0 &+ 2] = s0_0[2]; inter[o0 &+ 3] = s0_0[3]
                    inter[o0 &+ 4] = s0_1[0]; inter[o0 &+ 5] = s0_1[1]; inter[o0 &+ 6] = s0_1[2]; inter[o0 &+ 7] = s0_1[3]
                    inter[o0 &+ 8] = s0_2[0]; inter[o0 &+ 9] = s0_2[1]; inter[o0 &+ 10] = s0_2[2]; inter[o0 &+ 11] = s0_2[3]
                    inter[o0 &+ 12] = s0_3[0]; inter[o0 &+ 13] = s0_3[1]; inter[o0 &+ 14] = s0_3[2]; inter[o0 &+ 15] = s0_3[3]
                    let o1 = r1 &+ u
                    inter[o1] = s1_0[0]; inter[o1 &+ 1] = s1_0[1]; inter[o1 &+ 2] = s1_0[2]; inter[o1 &+ 3] = s1_0[3]
                    inter[o1 &+ 4] = s1_1[0]; inter[o1 &+ 5] = s1_1[1]; inter[o1 &+ 6] = s1_1[2]; inter[o1 &+ 7] = s1_1[3]
                    inter[o1 &+ 8] = s1_2[0]; inter[o1 &+ 9] = s1_2[1]; inter[o1 &+ 10] = s1_2[2]; inter[o1 &+ 11] = s1_2[3]
                    inter[o1 &+ 12] = s1_3[0]; inter[o1 &+ 13] = s1_3[1]; inter[o1 &+ 14] = s1_3[2]; inter[o1 &+ 15] = s1_3[3]
                }
                y &+= 2
            }
        } else if c == 4 {
            for y in 0..<r {
                let base = y &* 4
                var sums = SIMD4<Double>(repeating: 0)
                for x in 0..<4 {
                    sums += hPtr[x] * SIMD4<Double>(repeating: Double(inBase[base &+ x]))
                }
                inter[base] = sums[0]
                inter[base &+ 1] = sums[1]
                inter[base &+ 2] = sums[2]
                inter[base &+ 3] = sums[3]
            }
        } else {
            let colMat = cachedMatrixPointer(size: c, direction: direction)
            for y in 0..<r {
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
        }

        // 2. Vertical pass (SIMD4<Double> across output rows, 4 columns per batch when c >= 4)
        if r >= 8 && c >= 4 {
            let uSteps = r &>> 3
            var x = 0
            while x < c {
                for uStep in 0..<uSteps {
                    let u = uStep &* 8
                    let vBase0 = (uStep &* 2) &* r
                    let vBase1 = vBase0 &+ r
                    var sums0_0 = SIMD4<Double>(repeating: 0)
                    var sums0_1 = SIMD4<Double>(repeating: 0)
                    var sums0_2 = SIMD4<Double>(repeating: 0)
                    var sums0_3 = SIMD4<Double>(repeating: 0)
                    var sums1_0 = SIMD4<Double>(repeating: 0)
                    var sums1_1 = SIMD4<Double>(repeating: 0)
                    var sums1_2 = SIMD4<Double>(repeating: 0)
                    var sums1_3 = SIMD4<Double>(repeating: 0)
                    for y in 0..<r {
                        let w0 = vPtr[vBase0 &+ y]
                        let w1 = vPtr[vBase1 &+ y]
                        let tIdx = y &* c &+ x
                        let t0 = SIMD4<Double>(repeating: inter[tIdx])
                        let t1 = SIMD4<Double>(repeating: inter[tIdx &+ 1])
                        let t2 = SIMD4<Double>(repeating: inter[tIdx &+ 2])
                        let t3 = SIMD4<Double>(repeating: inter[tIdx &+ 3])
                        sums0_0 += w0 * t0; sums0_1 += w0 * t1; sums0_2 += w0 * t2; sums0_3 += w0 * t3
                        sums1_0 += w1 * t0; sums1_1 += w1 * t1; sums1_2 += w1 * t2; sums1_3 += w1 * t3
                    }
                    for lane in 0..<4 {
                        let oIdx0 = (u &+ lane) &* c &+ x
                        out[oIdx0] = Float(sums0_0[lane])
                        out[oIdx0 &+ 1] = Float(sums0_1[lane])
                        out[oIdx0 &+ 2] = Float(sums0_2[lane])
                        out[oIdx0 &+ 3] = Float(sums0_3[lane])
                        let oIdx1 = (u &+ 4 &+ lane) &* c &+ x
                        out[oIdx1] = Float(sums1_0[lane])
                        out[oIdx1 &+ 1] = Float(sums1_1[lane])
                        out[oIdx1 &+ 2] = Float(sums1_2[lane])
                        out[oIdx1 &+ 3] = Float(sums1_3[lane])
                    }
                }
                x &+= 4
            }
        } else if r == 4 && c >= 4 {
            var x = 0
            while x < c {
                var sums0 = SIMD4<Double>(repeating: 0)
                var sums1 = SIMD4<Double>(repeating: 0)
                var sums2 = SIMD4<Double>(repeating: 0)
                var sums3 = SIMD4<Double>(repeating: 0)
                for y in 0..<4 {
                    let weights = vPtr[y]
                    let tIdx = y &* c &+ x
                    sums0 += weights * SIMD4<Double>(repeating: inter[tIdx])
                    sums1 += weights * SIMD4<Double>(repeating: inter[tIdx &+ 1])
                    sums2 += weights * SIMD4<Double>(repeating: inter[tIdx &+ 2])
                    sums3 += weights * SIMD4<Double>(repeating: inter[tIdx &+ 3])
                }
                for lane in 0..<4 {
                    let oIdx = lane &* c &+ x
                    out[oIdx] = Float(sums0[lane])
                    out[oIdx &+ 1] = Float(sums1[lane])
                    out[oIdx &+ 2] = Float(sums2[lane])
                    out[oIdx &+ 3] = Float(sums3[lane])
                }
                x &+= 4
            }
        } else {
            let rowMat = cachedMatrixPointer(size: r, direction: direction)
            for x in 0..<c {
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
