// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTTransformTests {
    private struct Vector: Decodable {
        let rows: Int, cols: Int, pattern: Int
        let input: [Float], forward: [Float], inverse: [Float]
        let scalarForward: [Float], scalarInverse: [Float]
    }
    private func budget(_ bytes: Int = 4 * 1024 * 1024, expired: Bool = false) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: bytes,
            maximumMemoryBytes: bytes, maximumDecodedBytes: bytes,
            maximumCompressedBytes: bytes, deadline: .now.advanced(by: .seconds(expired ? -1 : 60)))
    }
    // Predeclared before migration: normalised input, absolute 2e-4 plus
    // relative 2e-5. This qualifies transforms, not pixel-codec fidelity.
    private func close(_ actual: [Float], _ expected: [Float]) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy {
            abs(Double($0) - Double($1)) <= 0.0002 + 0.00002 * abs(Double($1))
        }
    }
    private func vectors() throws -> [Vector] {
        let url = try #require(Bundle.module.url(forResource: "predecessor-dct", withExtension: "json", subdirectory: "VarDCT"))
        return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
    }

    @Test(arguments: [ScaledDCT.Direction.forward, .inverse])
    func matchesPredecessorAccelerateAndScalar(_ direction: ScaledDCT.Direction) throws {
        for v in try vectors() {
            let b = try budget()
            let plan = try ScaledDCT(rows: v.rows, columns: v.cols, direction: direction, budget: b)
            let actual = try plan.apply(v.input)
            let accelerated = direction == .forward ? v.forward : v.inverse
            let scalar = direction == .forward ? v.scalarForward : v.scalarInverse
            let knownPredecessorError = direction == .inverse &&
                ((v.rows == 64 && v.cols == 64 && v.pattern != 0) ||
                 (v.rows == 32 && v.cols == 16 && v.pattern == 2))
            if knownPredecessorError {
                let expected = reference(v.input, rows: v.rows, cols: v.cols, inverse: true)
                #expect(!close(accelerated, expected))
                #expect(!close(scalar, expected))
                let corrected = close(actual, expected)
                #expect(corrected, "Corrected predecessor error at \(v.rows)×\(v.cols), pattern \(v.pattern)")
            } else {
                let matchesAccelerated = close(actual, accelerated)
                let matchesScalar = close(actual, scalar)
                #expect(matchesAccelerated)
                #expect(matchesScalar)
            }
        }
    }

    /// Independent Double-precision definition of the separable cosine basis;
    /// no predecessor coefficients, matrix builder or Float arithmetic reused.
    private func reference(_ input: [Float], rows: Int, cols: Int, inverse: Bool) -> [Float] {
        func weight(_ output: Int, _ input: Int, _ n: Int) -> Double {
            let k = inverse ? input : output, t = inverse ? output : input
            let normalisation = k == 0 ? 1.0 : sqrt(2.0)
            return normalisation * cos(Double(2 * t + 1) * Double(k) * Double.pi / Double(2 * n)) / (inverse ? 1 : Double(n))
        }
        var horizontal = [Double](repeating: 0, count: input.count)
        var result = [Float](repeating: 0, count: input.count)
        for y in 0..<rows { for u in 0..<cols {
            for x in 0..<cols { horizontal[y * cols + u] += Double(input[y * cols + x]) * weight(u, x, cols) }
        } }
        for x in 0..<cols { for v in 0..<rows {
            var sum = 0.0
            for y in 0..<rows { sum += horizontal[y * cols + x] * weight(v, y, rows) }
            result[v * cols + x] = Float(sum)
        } }
        return result
    }

    @Test(arguments: [ScaledDCT.Direction.forward, .inverse])
    func independentDefinitionAndRoundTrip(_ direction: ScaledDCT.Direction) throws {
        for v in try vectors() {
            let b = try budget()
            let plan = try ScaledDCT(rows: v.rows, columns: v.cols, direction: direction, budget: b)
            let actual = try plan.apply(v.input)
            let matchesDefinition = close(actual, reference(v.input, rows: v.rows, cols: v.cols, inverse: direction == .inverse))
            #expect(matchesDefinition, "Definition at \(v.rows)×\(v.cols), pattern \(v.pattern)")
            if direction == .forward {
                let inverse = try ScaledDCT(rows: v.rows, columns: v.cols, direction: .inverse, budget: b)
                let roundTrip = try inverse.apply(actual)
                #expect(zip(roundTrip, v.input).allSatisfy { abs($0 - $1) <= 0.0002 })
            }
        }
    }

    @Test func rejectionAndExactAdmission() throws {
        for size in [Int.min, -1, 0, 1, 3, 65, Int.max] {
            #expect(throws: VarDCTError.invalidTransform) {
                try ScaledDCT(rows: size, columns: 8, direction: .inverse, budget: budget())
            }
        }
        let bytes = (8 * 8 + 16 * 16 + 2 * 8 * 16) * 4
        let b = try budget(bytes)
        let plan = try ScaledDCT(rows: 8, columns: 16, direction: .inverse, budget: b)
        let dc = [Float](repeating: 0, count: 128)
        #expect(try plan.apply(dc) == dc)
        #expect(b.reservedWorkspaceBytes == bytes)
        let short = try budget(bytes - 1)
        let other = try ScaledDCT(rows: 8, columns: 16, direction: .inverse, budget: short)
        #expect(throws: (any Error).self) { try other.apply(dc) }
        #expect(throws: VarDCTError.invalidTransform) { try plan.apply([]) }
        for invalid: Float in [.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            let values = [Float](repeating: invalid, count: 128)
            let fresh = try ScaledDCT(rows: 8, columns: 16, direction: .inverse, budget: budget())
            #expect(throws: VarDCTError.nonFiniteSample) { try fresh.apply(values) }
        }
        #expect(throws: (any Error).self) { try plan.apply(dc) } // cumulative budget, no rebinding
        #expect(b.reservedWorkspaceBytes == bytes)
        #expect(throws: (any Error).self) {
            try ScaledDCT(rows: 8, columns: 16, direction: .inverse, budget: budget(expired: true))
        }
    }

    @Test func sharedPlanAccountsForConcurrentScratch() async throws {
        let b = try budget(1536)
        let plan = try ScaledDCT(rows: 8, columns: 8, direction: .inverse, budget: b)
        var values = [Float](repeating: 0, count: 64)
        values[0] = 0.75
        let input = values
        try await withThrowingTaskGroup(of: [Float].self) { group in
            for _ in 0..<2 { group.addTask { try plan.apply(input) } }
            for try await result in group { #expect(result.allSatisfy { $0 == 0.75 }) }
        }
        #expect(b.reservedWorkspaceBytes == 1536)
        #expect(throws: (any Error).self) { try plan.apply(input) }
    }

    @Test func cancelledOperationRejectsBeforeAdmission() async throws {
        let b = try budget()
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try ScaledDCT(rows: 8, columns: 8, direction: .forward, budget: b); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        #expect(result)
        #expect(b.reservedWorkspaceBytes == 0)
    }
}
