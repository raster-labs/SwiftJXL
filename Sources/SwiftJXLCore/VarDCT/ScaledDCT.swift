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
    package enum Direction: Sendable { case forward, inverse }
    package let rows: Int
    package let columns: Int
    private let budget: ScalarOperationBudget
    private let rowMatrix: [Float]
    private let columnMatrix: [Float]

    package init(rows: Int, columns: Int, direction: Direction,
                 budget: ScalarOperationBudget) throws {
        guard Self.valid(rows), Self.valid(columns) else { throw VarDCTError.invalidTransform }
        self.rows = rows; self.columns = columns; self.budget = budget
        // Checked axes bound all following products. Charge both matrices even
        // for square blocks, before allocation, through the operation budget.
        try budget.reserveWorkspace((rows * rows + columns * columns) * MemoryLayout<Float>.stride)
        rowMatrix = try Self.matrix(rows, direction: direction, budget: budget)
        columnMatrix = try Self.matrix(columns, direction: direction, budget: budget)
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
                for x in 0..<columns { sum += Double(columnMatrix[u * columns + x]) * Double(input[y * columns + x]) }
                guard Float(sum).isFinite else { throw VarDCTError.nonFiniteSample }
                temporary[y * columns + u] = Float(sum)
            }
        }
        for x in 0..<columns {
            try budget.checkpoint()
            for u in 0..<rows {
                var sum: Double = 0
                for y in 0..<rows { sum += Double(rowMatrix[u * rows + y]) * Double(temporary[y * columns + x]) }
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
    }

    /// Synchronous source borrow; no pointer escapes. The caller retains the
    /// input owner until return. Scratch is allocated once and never copied.
    package func apply(_ input: UnsafeBufferPointer<Float>, workspace: inout Workspace) throws {
        try budget.checkpoint()
        guard input.count == rows * columns, workspace.output.count >= input.count,
              workspace.budget === budget else { throw VarDCTError.invalidTransform }
        guard input.allSatisfy(\.isFinite) else { throw VarDCTError.nonFiniteSample }
        for y in 0..<rows {
            try budget.checkpoint()
            for u in 0..<columns {
                var sum: Double = 0
                for x in 0..<columns { sum += Double(columnMatrix[u * columns + x]) * Double(input[y * columns + x]) }
                guard Float(sum).isFinite else { throw VarDCTError.nonFiniteSample }
                workspace.temporary[y * columns + u] = Float(sum)
            }
        }
        for x in 0..<columns {
            try budget.checkpoint()
            for u in 0..<rows {
                var sum: Double = 0
                for y in 0..<rows { sum += Double(rowMatrix[u * rows + y]) * Double(workspace.temporary[y * columns + x]) }
                guard Float(sum).isFinite else { throw VarDCTError.nonFiniteSample }
                workspace.output[u * columns + x] = Float(sum)
            }
        }
        try budget.checkpoint()
    }

    private static func valid(_ n: Int) -> Bool { (2...64).contains(n) && n & (n - 1) == 0 }
    private static func matrix(_ n: Int, direction: Direction,
                               budget: ScalarOperationBudget) throws -> [Float] {
        // Double angles avoid the large-block Float-angle error measured in
        // the pinned predecessor. Matrices/storage remain Float; sums widen.
        let nf = Double(n), rootTwo = sqrt(2.0)
        let scale = direction == .forward ? rootTwo / nf : rootTwo
        var result = [Float](repeating: 0, count: n * n)
        for u in 0..<n {
            try budget.checkpoint()
            for y in 0..<n {
                let frequency = direction == .forward ? u : y
                let position = direction == .forward ? y : u
                let alpha = frequency == 0 ? 1 / rootTwo : 1
                let angle = (Double(position) + 0.5) * Double(frequency) * .pi / nf
                result[u * n + y] = Float(alpha * cos(angle) * scale)
            }
        }
        return result
    }
}
