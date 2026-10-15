// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTWorkspaceTests {
    private func budget(_ bytes: Int = 32 * 1024 * 1024,
                        cancellation: ScalarOperationCancellation? = nil) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: bytes,
            maximumMemoryBytes: bytes, maximumDecodedBytes: bytes,
            maximumCompressedBytes: bytes, deadline: .now.advanced(by: .seconds(60)), cancellation: cancellation)
    }
    @Test func smallScratchReusesAdmissionAndOverwritesEveryStrategy() throws {
        let operation = try budget(16 * 1024), reference = try VarDCTSmallAnalysis(budget: budget())
        let plan = try VarDCTSmallAnalysis(budget: operation)
        var scratch = try VarDCTSmallAnalysis.Workspace(budget: operation)
        let admitted = operation.reservedWorkspaceBytes
        for repetition in 0..<3 { for id in [17,0,16,1,15,2,14,3,13,12] {
            let pixels = (0..<64).map { Float(($0 * 17 + repetition * 11) % 29 - 14) / 31 }
            let expected = try reference.apply(pixels, identifier: id)
            try pixels.withUnsafeBufferPointer { try plan.apply($0, identifier: id, workspace: &scratch) }
            for i in 0..<64 { #expect(scratch.value(at: i) == expected[i]) }
            #expect(operation.reservedWorkspaceBytes == admitted)
        } }
    }
    @Test func largeScratchReusesAdmissionAcrossShapes() throws {
        let operation = try budget(), referenceBudget = try budget()
        var scratch = try VarDCTLargeAnalysis.Workspace(budget: operation)
        for id in [18,6,20,4,8,19,5,9,7,10,11] {
            let plan = try VarDCTLargeAnalysis(identifier: id, budget: operation)
            let reference = try VarDCTLargeAnalysis(identifier: id, budget: referenceBudget)
            let admitted = operation.reservedWorkspaceBytes
            for repetition in 0..<2 {
                let count = plan.rows * plan.columns
                let pixels = (0..<count).map { Float(($0 * 11 + repetition * 3) % 23 - 11) / 29 }
                let expected = try reference.apply(pixels)
                try pixels.withUnsafeBufferPointer { try plan.apply($0, workspace: &scratch) }
                for i in 0..<count { #expect(scratch.coefficient(at: i) == expected.coefficients[i]) }
                for i in 0..<(count / 64) { #expect(scratch.dcValue(at: i) == expected.dc[i]) }
                #expect(operation.reservedWorkspaceBytes == admitted)
            }
        }
    }
    @Test(arguments: [2, 4, 8, 16, 32, 64])
    func scopedDCTBorrowPreservesScalarArithmetic(_ rows: Int) throws {
        for columns in [2, 8, 64] {
            for direction in [ScaledDCT.Direction.forward, .inverse] {
                let operation = try budget()
                let plan = try ScaledDCT(rows: rows, columns: columns, direction: direction, budget: operation)
                var scratch = try ScaledDCT.Workspace(capacity: rows * columns, budget: operation)
                for seed in [0, 1] {
                    let pixels = (0..<(rows * columns)).map { Float(($0 * 113 + seed * 29) % 257 - 128) / 31 }
                    let expected = try plan.apply(pixels)
                    let admitted = operation.reservedWorkspaceBytes
                    try pixels.withUnsafeBufferPointer { try plan.apply($0, workspace: &scratch) }
                    for index in pixels.indices { #expect(scratch.value(at: index).bitPattern == expected[index].bitPattern) }
                    #expect(operation.reservedWorkspaceBytes == admitted)
                }
            }
        }
    }

    @Test(arguments: [4,5,6,7,8,9,10,11,18,19,20])
    func cachedLargeDCFactorsRetainOriginalArithmetic(_ identifier: Int) throws {
        let operation = try budget(), plan = try VarDCTLargeAnalysis(identifier: identifier, budget: operation)
        let count = plan.rows * plan.columns, cellsX = plan.columns / 8, cellsY = plan.rows / 8
        let input = (0..<count).map { Float(($0 * 113 + 29) % 257 - 128) / 31 }
        let scalar = try ScaledDCT(rows: plan.rows, columns: plan.columns, direction: .forward, budget: operation).apply(input)
        var scratch = try VarDCTLargeAnalysis.Workspace(capacity: count, budget: operation)
        try input.withUnsafeBufferPointer { try plan.apply($0, workspace: &scratch) }
        for y in 0..<plan.rows { for x in 0..<plan.columns {
            let target = plan.rows >= plan.columns ? x * plan.rows + y : y * plan.columns + x
            #expect(scratch.coefficient(at: target).bitPattern == scalar[y * plan.columns + x].bitPattern)
        } }
        // Uncached definition retained from the original implementation. Keep
        // every division and multiplication in the normative evaluation order.
        let scales: [Int: [Double]] = [1:[1],2:[1,1.108937353592731823],
            4:[1,1.025760096781116015,1.108937353592731823,1.270559368765487251],
            8:[1,1.0063534990068217,1.0257600967811158,1.0593017296817173,
                1.1089373535927318,1.1777765381970435,1.2705593687654873,1.3944898413647777]]
        let sx = try #require(scales[cellsX]), sy = try #require(scales[cellsY])
        for y in 0..<cellsY { for x in 0..<cellsX {
            var sum: Double = 0
            for v in 0..<cellsY { for u in 0..<cellsX {
                let value = Double(scalar[v * plan.columns + u]) / (sx[u] * sy[v])
                let normalisation = (u == 0 ? 1 : sqrt(2)) * (v == 0 ? 1 : sqrt(2))
                sum += value * normalisation * cos((Double(x) + 0.5) * Double(u) * .pi / Double(cellsX))
                    * cos((Double(y) + 0.5) * Double(v) * .pi / Double(cellsY))
            } }
            #expect(scratch.dcValue(at: y * cellsX + x).bitPattern == Float(sum).bitPattern)
        } }
    }


    @Test(arguments: [ScaledDCT.Direction.forward, .inverse])
    func sharedAxesPreserveEveryShapeAndAdmission(_ direction: ScaledDCT.Direction) throws {
        let operation = try budget()
        var axes = ScaledDCT.AxisBank(direction: direction, budget: operation)
        for rows in [2, 4, 8, 16, 32, 64] { for columns in [2, 8, 64] {
            let shared = try ScaledDCT(rows: rows, columns: columns, direction: direction,
                budget: operation, axes: &axes)
            let reference = try ScaledDCT(rows: rows, columns: columns, direction: direction, budget: budget())
            let input = (0..<(rows * columns)).map { Float(($0 * 31 + rows * 7) % 113 - 56) / 37 }
            let actual = try shared.apply(input), expected = try reference.apply(input)
            for i in input.indices { #expect(actual[i].bitPattern == expected[i].bitPattern) }
        } }
        let before = operation.reservedWorkspaceBytes
        #expect(throws: VarDCTError.invalidTransform) {
            _ = try ScaledDCT(rows: 8, columns: 8, direction: direction, budget: budget(), axes: &axes)
        }
        #expect(throws: VarDCTError.invalidTransform) {
            _ = try ScaledDCT(rows: 8, columns: 8, direction: direction == .forward ? .inverse : .forward,
                budget: operation, axes: &axes)
        }
        #expect(throws: VarDCTError.invalidTransform) {
            _ = try ScaledDCT(rows: 3, columns: 8, direction: direction, budget: operation, axes: &axes)
        }
        #expect(operation.reservedWorkspaceBytes == before)
        let limited = try budget(1024)
        var limitedAxes = ScaledDCT.AxisBank(direction: direction, budget: limited)
        _ = try ScaledDCT(rows: 8, columns: 8, direction: direction, budget: limited, axes: &limitedAxes)
        #expect(throws: ScalarModularError.self) {
            _ = try ScaledDCT(rows: 8, columns: 8, direction: direction, budget: limited, axes: &limitedAxes)
        }
        #expect(limited.reservedWorkspaceBytes == 1024)
        let cancellation = ScalarOperationCancellation(), cancelled = try budget(cancellation: cancellation)
        var cancelledAxes = ScaledDCT.AxisBank(direction: direction, budget: cancelled)
        cancellation.cancel()
        #expect(throws: CancellationError.self) {
            _ = try ScaledDCT(rows: 8, columns: 8, direction: direction, budget: cancelled, axes: &cancelledAxes)
        }
        #expect(cancelled.reservedWorkspaceBytes == 0)
    }

    @Test(arguments: [2, 64])
    func scopedDCTRejectsCancellationBeforeScratchWrite(_ axis: Int) throws {
        let cancellation = ScalarOperationCancellation(), operation = try budget(cancellation: cancellation)
        let plan = try ScaledDCT(rows: axis, columns: axis, direction: .forward, budget: operation)
        var scratch = try ScaledDCT.Workspace(capacity: axis * axis, budget: operation)
        let input = (0..<(axis * axis)).map { Float($0 % 13) / 31 }
        try input.withUnsafeBufferPointer { try plan.apply($0, workspace: &scratch) }
        let before = (0..<input.count).map { scratch.value(at: $0).bitPattern }
        cancellation.cancel()
        #expect(throws: CancellationError.self) {
            try input.withUnsafeBufferPointer { try plan.apply($0, workspace: &scratch) }
        }
        for i in input.indices { #expect(scratch.value(at: i).bitPattern == before[i]) }
    }

    @Test func scratchCannotCrossBudgetsOrAdmitInsufficientCapacity() throws {
        let operation = try budget(), other = try budget()
        let small = try VarDCTSmallAnalysis(budget: operation)
        var wrong = try VarDCTSmallAnalysis.Workspace(budget: other)
        let pixels = [Float](repeating: 0, count: 64)
        #expect(throws: VarDCTError.invalidTransform) {
            try pixels.withUnsafeBufferPointer { try small.apply($0, identifier: 0, workspace: &wrong) }
        }
        let large = try VarDCTLargeAnalysis(identifier: 4, budget: operation)
        var short = try VarDCTLargeAnalysis.Workspace(capacity: 64, budget: operation)
        #expect(throws: VarDCTError.invalidTransform) {
            try [Float](repeating: 0, count: 256).withUnsafeBufferPointer { try large.apply($0, workspace: &short) }
        }
        let dct = try ScaledDCT(rows: 16, columns: 8, direction: .forward, budget: operation)
        var dctShort = try ScaledDCT.Workspace(capacity: 64, budget: operation)
        #expect(throws: VarDCTError.invalidTransform) {
            try [Float](repeating: 0, count: 128).withUnsafeBufferPointer { try dct.apply($0, workspace: &dctShort) }
        }
        #expect(throws: (any Error).self) { _ = try VarDCTSmallAnalysis.Workspace(budget: budget(1)) }
        #expect(throws: (any Error).self) { _ = try VarDCTLargeAnalysis.Workspace(budget: budget(1)) }
    }
    @Test func cancellationDoesNotOverwriteAdmittedScratch() throws {
        let cancellation = ScalarOperationCancellation(), operation = try budget(cancellation: cancellation)
        let plan = try VarDCTSmallAnalysis(budget: operation)
        var scratch = try VarDCTSmallAnalysis.Workspace(budget: operation)
        let pixels = [Float](repeating: 0.375, count: 64)
        try pixels.withUnsafeBufferPointer { try plan.apply($0, identifier: 0, workspace: &scratch) }
        let before = (0..<64).map { scratch.value(at: $0) }
        let large = try VarDCTLargeAnalysis(identifier: 6, budget: operation)
        var largeScratch = try VarDCTLargeAnalysis.Workspace(budget: operation)
        let largePixels = (0..<128).map { Float($0 % 19 - 9) / 23 }
        try largePixels.withUnsafeBufferPointer { try large.apply($0, workspace: &largeScratch) }
        let beforeLarge = (0..<128).map { largeScratch.coefficient(at: $0).bitPattern }
        let beforeDC = (0..<2).map { largeScratch.dcValue(at: $0).bitPattern }
        let admitted = operation.reservedWorkspaceBytes
        cancellation.cancel()
        #expect(throws: CancellationError.self) {
            try pixels.withUnsafeBufferPointer { try plan.apply($0, identifier: 1, workspace: &scratch) }
        }
        #expect(throws: CancellationError.self) {
            try largePixels.withUnsafeBufferPointer { try large.apply($0, workspace: &largeScratch) }
        }
        for i in 0..<128 { #expect(largeScratch.coefficient(at: i).bitPattern == beforeLarge[i]) }
        for i in 0..<2 { #expect(largeScratch.dcValue(at: i).bitPattern == beforeDC[i]) }
        #expect(operation.reservedWorkspaceBytes == admitted)
        for i in 0..<64 { #expect(scratch.value(at: i) == before[i]) }
    }
}
