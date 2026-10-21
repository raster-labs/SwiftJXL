// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift VarDCT/LibjxlIDCT.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors' scaled DCT convention, ISO/IEC 18181-1 §C.9.
// See Documentation/ThirdParty/libjxl-LICENSE.txt.
import Foundation

package enum VarDCTError: Error, Equatable { case invalidTransform, nonFiniteSample
    case unsupportedStrategy(Int) }

/// Operation-owned scalar transform matrices. No global cache or unsafe borrow.
/// Axes are powers of two from 2 through 64; DC is the sample mean. This is
/// the reference path for subsequent pixel integration, not a public codec mode.
package struct ScaledDCT: Sendable {
    package enum Direction: Sendable, Equatable { case forward, inverse }
    package let rows: Int
    package let columns: Int
    private let budget: ScalarOperationBudget
    // Four output-frequency lanes per input sample. Coefficients are rounded
    // through Float once, retaining the reference matrix exactly; promotion to
    // Double is moved out of every dot product into plan construction.
    private let rowMatrix: [SIMD4<Double>]
    private let columnMatrix: [SIMD4<Double>]

    /// Construction-only axis owners, scoped to one operation and direction.
    /// Fixed slots need no additional dictionary/array allocation. Plans retain
    /// immutable Array owners; the mutable bank never enters parallel work.
    package struct AxisBank: ~Copyable {
        fileprivate let budget: ScalarOperationBudget
        fileprivate let direction: Direction
        private var axis2: [SIMD4<Double>]?, axis4: [SIMD4<Double>]?
        private var axis8: [SIMD4<Double>]?, axis16: [SIMD4<Double>]?
        private var axis32: [SIMD4<Double>]?, axis64: [SIMD4<Double>]?
        package init(direction: Direction, budget: ScalarOperationBudget) {
            self.direction = direction; self.budget = budget
        }
        fileprivate mutating func matrix(_ n: Int) throws -> [SIMD4<Double>] {
            try budget.checkpoint()
            let cached: [SIMD4<Double>]?
            switch n {
            case 2: cached = axis2
            case 4: cached = axis4
            case 8: cached = axis8
            case 16: cached = axis16
            case 32: cached = axis32
            case 64: cached = axis64
            default: throw VarDCTError.invalidTransform
            }
            if let cached { return cached }
            let value = try ScaledDCT.matrix(n, direction: direction, budget: budget)
            switch n {
            case 2: axis2 = value
            case 4: axis4 = value
            case 8: axis8 = value
            case 16: axis16 = value
            case 32: axis32 = value
            default: axis64 = value
            }
            return value
        }
    }

    package init(rows: Int, columns: Int, direction: Direction,
                 budget: ScalarOperationBudget) throws {
        var axes = AxisBank(direction: direction, budget: budget)
        try self.init(rows: rows, columns: columns, direction: direction, budget: budget, axes: &axes)
    }
    package init(rows: Int, columns: Int, direction: Direction,
                 budget: ScalarOperationBudget, axes: inout AxisBank) throws {
        guard Self.valid(rows), Self.valid(columns), axes.budget === budget,
              axes.direction == direction else { throw VarDCTError.invalidTransform }
        self.rows = rows; self.columns = columns; self.budget = budget
        // Preserve conservative per-plan admission even when an immutable axis
        // owner is shared. No cache hit can bypass this operation's budget.
        try budget.reserveWorkspace(((rows + 3) / 4 * rows + (columns + 3) / 4 * columns) * MemoryLayout<SIMD4<Double>>.stride)
        rowMatrix = try axes.matrix(rows)
        columnMatrix = try axes.matrix(columns)
    }

    /// Plans retain their operation budget, so copying a plan cannot evade admission.
    /// Concurrent calls own separate admitted scratch within that same operation.
    /// Input stays unchanged on cancellation, malformed samples or exhaustion.
    package func apply(_ input: [Float]) throws -> [Float] {
        try budget.checkpoint()
        guard input.count == rows * columns else { throw VarDCTError.invalidTransform }
        guard input.allSatisfy(\.isFinite) else { throw VarDCTError.nonFiniteSample }
        try budget.reserveWorkspace(input.count * MemoryLayout<Float>.stride * 2)
        var temporary = [Float](repeating: 0, count: input.count)
        var output = [Float](repeating: 0, count: input.count)
        // Horizontal pass, then vertical pass, matching predecessor ordering.
        // At most 4096 multiply-adds between cancellation/deadline checks.
        for y in 0..<rows {
            try budget.checkpoint()
            for u in 0..<columns {
                var sum: Double = 0
                for x in 0..<columns { sum += columnMatrix[(u / 4) * columns + x][u % 4] * Double(input[y * columns + x]) }
                guard Float(sum).isFinite else { throw VarDCTError.nonFiniteSample }
                temporary[y * columns + u] = Float(sum)
            }
        }
        for x in 0..<columns {
            try budget.checkpoint()
            for u in 0..<rows {
                var sum: Double = 0
                for y in 0..<rows { sum += rowMatrix[(u / 4) * rows + y][u % 4] * Double(temporary[y * columns + x]) }
                guard Float(sum).isFinite else { throw VarDCTError.nonFiniteSample }
                output[u * columns + x] = Float(sum)
            }
        }
        try budget.checkpoint()
        return output
    }

    /// Non-copyable storage prevents Array COW aliases from creating uncharged
    /// allocations. It is bound to one budget and borrowed exclusively by apply.
    package struct Workspace: ~Copyable {
        fileprivate let budget: ScalarOperationBudget
        fileprivate var temporary: [Float], output: [Float]
        package init(capacity: Int, budget: ScalarOperationBudget) throws {
            guard (1...4096).contains(capacity) else { throw VarDCTError.invalidTransform }
            try budget.reserveWorkspace(capacity * MemoryLayout<Float>.stride * 2)
            self.budget = budget
            temporary = [Float](repeating: 0, count: capacity)
            output = [Float](repeating: 0, count: capacity)
        }
        package func value(at index: Int) -> Float { output[index] }
        /// Synchronous read borrow; callers may not retain the pointer.
        package borrowing func withValues<Result>(_ body: (UnsafeBufferPointer<Float>) throws -> Result) rethrows -> Result {
            try output.withUnsafeBufferPointer(body)
        }
    }

    /// Synchronous source borrow; no pointer escapes. The caller retains the
    /// input owner until return. Scratch is allocated once and never copied.
    package func apply(_ input: UnsafeBufferPointer<Float>, workspace: inout Workspace) throws {
        try budget.checkpoint()
        let count = rows &* columns
        guard input.count == count, workspace.output.count >= count,
              workspace.budget === budget, let inBase = input.baseAddress else { throw VarDCTError.invalidTransform }
        for i in 0..<count {
            if !inBase[i].isFinite { throw VarDCTError.nonFiniteSample }
        }
        // All four borrows are synchronous and cover one bounded transform.
        // The noncopyable workspace supplies disjoint uniquely owned arrays;
        // establishing uniqueness once removes a COW check per output sample.
        try columnMatrix.withUnsafeBufferPointer { horizontal in
            try rowMatrix.withUnsafeBufferPointer { vertical in
                try workspace.temporary.withUnsafeMutableBufferPointer { temporary in
                    try workspace.output.withUnsafeMutableBufferPointer { output in
                        let hPtr = horizontal.baseAddress!
                        let vPtr = vertical.baseAddress!
                        let tempPtr = temporary.baseAddress!
                        let outPtr = output.baseAddress!
                        let hStep = max(1, 4096 / (columns &* columns))
                        for y in 0..<rows {
                            // Batch complete rows within the original bound:
                            // no more than 4096 multiply-adds between checks.
                            if y % hStep == 0 { try budget.checkpoint() }
                            let base = y &* columns
                            var u = 0
                            // Four independent dot products share each input
                            // load. Every lane retains the scalar sum order;
                            // no horizontal reassociation or reduced precision.
                            while u &+ 15 < columns {
                                var sums0 = SIMD4<Double>(repeating: 0)
                                var sums1 = SIMD4<Double>(repeating: 0)
                                var sums2 = SIMD4<Double>(repeating: 0)
                                var sums3 = SIMD4<Double>(repeating: 0)
                                let hBase0 = (u &>> 2) &* columns
                                let hBase1 = hBase0 &+ columns
                                let hBase2 = hBase1 &+ columns
                                let hBase3 = hBase2 &+ columns
                                for x in 0..<columns {
                                    let s = SIMD4<Double>(repeating: Double(inBase[base &+ x]))
                                    sums0 += hPtr[hBase0 &+ x] * s
                                    sums1 += hPtr[hBase1 &+ x] * s
                                    sums2 += hPtr[hBase2 &+ x] * s
                                    sums3 += hPtr[hBase3 &+ x] * s
                                }
                                let v0 = Float(sums0[0]), v1 = Float(sums0[1]), v2 = Float(sums0[2]), v3 = Float(sums0[3])
                                let v4 = Float(sums1[0]), v5 = Float(sums1[1]), v6 = Float(sums1[2]), v7 = Float(sums1[3])
                                let v8 = Float(sums2[0]), v9 = Float(sums2[1]), v10 = Float(sums2[2]), v11 = Float(sums2[3])
                                let v12 = Float(sums3[0]), v13 = Float(sums3[1]), v14 = Float(sums3[2]), v15 = Float(sums3[3])
                                guard v0.isFinite && v1.isFinite && v2.isFinite && v3.isFinite &&
                                      v4.isFinite && v5.isFinite && v6.isFinite && v7.isFinite &&
                                      v8.isFinite && v9.isFinite && v10.isFinite && v11.isFinite &&
                                      v12.isFinite && v13.isFinite && v14.isFinite && v15.isFinite else {
                                    throw VarDCTError.nonFiniteSample
                                }
                                let oIdx = base &+ u
                                tempPtr[oIdx] = v0; tempPtr[oIdx &+ 1] = v1; tempPtr[oIdx &+ 2] = v2; tempPtr[oIdx &+ 3] = v3
                                tempPtr[oIdx &+ 4] = v4; tempPtr[oIdx &+ 5] = v5; tempPtr[oIdx &+ 6] = v6; tempPtr[oIdx &+ 7] = v7
                                tempPtr[oIdx &+ 8] = v8; tempPtr[oIdx &+ 9] = v9; tempPtr[oIdx &+ 10] = v10; tempPtr[oIdx &+ 11] = v11
                                tempPtr[oIdx &+ 12] = v12; tempPtr[oIdx &+ 13] = v13; tempPtr[oIdx &+ 14] = v14; tempPtr[oIdx &+ 15] = v15
                                u &+= 16
                            }
                            while u &+ 7 < columns {
                                var sums0 = SIMD4<Double>(repeating: 0)
                                var sums1 = SIMD4<Double>(repeating: 0)
                                let hBase0 = (u &>> 2) &* columns
                                let hBase1 = hBase0 &+ columns
                                for x in 0..<columns {
                                    let s = SIMD4<Double>(repeating: Double(inBase[base &+ x]))
                                    sums0 += hPtr[hBase0 &+ x] * s
                                    sums1 += hPtr[hBase1 &+ x] * s
                                }
                                let v0 = Float(sums0[0]), v1 = Float(sums0[1]), v2 = Float(sums0[2]), v3 = Float(sums0[3])
                                let v4 = Float(sums1[0]), v5 = Float(sums1[1]), v6 = Float(sums1[2]), v7 = Float(sums1[3])
                                guard v0.isFinite && v1.isFinite && v2.isFinite && v3.isFinite &&
                                      v4.isFinite && v5.isFinite && v6.isFinite && v7.isFinite else {
                                    throw VarDCTError.nonFiniteSample
                                }
                                let oIdx = base &+ u
                                tempPtr[oIdx] = v0; tempPtr[oIdx &+ 1] = v1; tempPtr[oIdx &+ 2] = v2; tempPtr[oIdx &+ 3] = v3
                                tempPtr[oIdx &+ 4] = v4; tempPtr[oIdx &+ 5] = v5; tempPtr[oIdx &+ 6] = v6; tempPtr[oIdx &+ 7] = v7
                                u &+= 8
                            }
                            while u &+ 3 < columns {
                                var sums = SIMD4<Double>(repeating: 0)
                                let hBase = (u &>> 2) &* columns
                                for x in 0..<columns {
                                    sums += hPtr[hBase &+ x] * SIMD4<Double>(repeating: Double(inBase[base &+ x]))
                                }
                                let v0 = Float(sums[0]), v1 = Float(sums[1]), v2 = Float(sums[2]), v3 = Float(sums[3])
                                guard v0.isFinite && v1.isFinite && v2.isFinite && v3.isFinite else {
                                    throw VarDCTError.nonFiniteSample
                                }
                                let oIdx = base &+ u
                                tempPtr[oIdx] = v0; tempPtr[oIdx &+ 1] = v1; tempPtr[oIdx &+ 2] = v2; tempPtr[oIdx &+ 3] = v3
                                u &+= 4
                            }
                            while u < columns {
                                var sum: Double = 0
                                let hBase = (u &>> 2) &* columns, lane = u & 3
                                for x in 0..<columns {
                                    sum += hPtr[hBase &+ x][lane] * Double(inBase[base &+ x])
                                }
                                let value = Float(sum)
                                guard value.isFinite else { throw VarDCTError.nonFiniteSample }
                                tempPtr[base &+ u] = value
                                u &+= 1
                            }
                        }
                        // Each 4-column vertical batch performs 4 * rows * rows
                        // scalar multiply-adds (16 * rows per 4-frequency step).
                        // Keep at most 4096 scalar multiply-adds between checks
                        // across column batches and within 64-row batches.
                        let vBatchStep = max(4, 4096 / (rows &* rows))
                        let vFreqStep = max(4, 4096 / (4 &* rows))
                        var x = 0
                        while x &+ 3 < columns {
                            if x % vBatchStep == 0 { try budget.checkpoint() }
                            var u = 0
                            while u &+ 3 < rows {
                                if u > 0 && u % vFreqStep == 0 { try budget.checkpoint() }
                                var sums0 = SIMD4<Double>(repeating: 0)
                                var sums1 = SIMD4<Double>(repeating: 0)
                                var sums2 = SIMD4<Double>(repeating: 0)
                                var sums3 = SIMD4<Double>(repeating: 0)
                                let vBase = (u &>> 2) &* rows
                                for y in 0..<rows {
                                    let weights = vPtr[vBase &+ y]
                                    let tIdx = y &* columns &+ x
                                    sums0 += weights * SIMD4<Double>(repeating: Double(tempPtr[tIdx]))
                                    sums1 += weights * SIMD4<Double>(repeating: Double(tempPtr[tIdx &+ 1]))
                                    sums2 += weights * SIMD4<Double>(repeating: Double(tempPtr[tIdx &+ 2]))
                                    sums3 += weights * SIMD4<Double>(repeating: Double(tempPtr[tIdx &+ 3]))
                                }
                                for lane in 0..<4 {
                                    let v0 = Float(sums0[lane]), v1 = Float(sums1[lane]), v2 = Float(sums2[lane]), v3 = Float(sums3[lane])
                                    guard v0.isFinite && v1.isFinite && v2.isFinite && v3.isFinite else {
                                        throw VarDCTError.nonFiniteSample
                                    }
                                    let oIdx = (u &+ lane) &* columns &+ x
                                    outPtr[oIdx] = v0; outPtr[oIdx &+ 1] = v1; outPtr[oIdx &+ 2] = v2; outPtr[oIdx &+ 3] = v3
                                }
                                u &+= 4
                            }
                            while u < rows {
                                var sum0: Double = 0, sum1: Double = 0, sum2: Double = 0, sum3: Double = 0
                                let vBase = (u &>> 2) &* rows, lane = u & 3
                                for y in 0..<rows {
                                    let w = vPtr[vBase &+ y][lane]
                                    let tIdx = y &* columns &+ x
                                    sum0 += w * Double(tempPtr[tIdx])
                                    sum1 += w * Double(tempPtr[tIdx &+ 1])
                                    sum2 += w * Double(tempPtr[tIdx &+ 2])
                                    sum3 += w * Double(tempPtr[tIdx &+ 3])
                                }
                                let v0 = Float(sum0), v1 = Float(sum1), v2 = Float(sum2), v3 = Float(sum3)
                                guard v0.isFinite && v1.isFinite && v2.isFinite && v3.isFinite else {
                                    throw VarDCTError.nonFiniteSample
                                }
                                let oIdx = u &* columns &+ x
                                outPtr[oIdx] = v0; outPtr[oIdx &+ 1] = v1; outPtr[oIdx &+ 2] = v2; outPtr[oIdx &+ 3] = v3
                                u &+= 1
                            }
                            x &+= 4
                        }
                        let vSingleStep = max(1, 4096 / (rows &* rows))
                        while x < columns {
                            if x % vSingleStep == 0 { try budget.checkpoint() }
                            var u = 0
                            while u &+ 3 < rows {
                                var sums = SIMD4<Double>(repeating: 0)
                                let vBase = (u &>> 2) &* rows
                                for y in 0..<rows {
                                    let weights = vPtr[vBase &+ y]
                                    sums += weights * SIMD4<Double>(repeating: Double(tempPtr[y &* columns &+ x]))
                                }
                                for lane in 0..<4 {
                                    let value = Float(sums[lane])
                                    guard value.isFinite else { throw VarDCTError.nonFiniteSample }
                                    outPtr[(u &+ lane) &* columns &+ x] = value
                                }
                                u &+= 4
                            }
                            while u < rows {
                                var sum: Double = 0
                                let vBase = (u &>> 2) &* rows, lane = u & 3
                                for y in 0..<rows {
                                    sum += vPtr[vBase &+ y][lane] * Double(tempPtr[y &* columns &+ x])
                                }
                                let value = Float(sum)
                                guard value.isFinite else { throw VarDCTError.nonFiniteSample }
                                outPtr[u &* columns &+ x] = value
                                u &+= 1
                            }
                            x &+= 1
                        }
                    }
                }
            }
        }
        try budget.checkpoint()
    }

    private static func valid(_ n: Int) -> Bool { (2...64).contains(n) && n & (n - 1) == 0 }
    private static func matrix(_ n: Int, direction: Direction,
                               budget: ScalarOperationBudget) throws -> [SIMD4<Double>] {
        // Double angles avoid the large-block Float-angle error measured in
        // the pinned predecessor. Coefficients retain Float rounding; sums widen.
        let nf = Double(n), rootTwo = sqrt(2.0)
        let scale = direction == .forward ? rootTwo / nf : rootTwo
        var result = [SIMD4<Double>](repeating: .zero, count: (n + 3) / 4 * n)
        for u in 0..<n {
            try budget.checkpoint()
            for y in 0..<n {
                let frequency = direction == .forward ? u : y
                let position = direction == .forward ? y : u
                let alpha = frequency == 0 ? 1 / rootTwo : 1
                let angle = (Double(position) + 0.5) * Double(frequency) * .pi / nf
                result[(u / 4) * n + y][u % 4] = Double(Float(alpha * cos(angle) * scale))
            }
        }
        return result
    }
}
