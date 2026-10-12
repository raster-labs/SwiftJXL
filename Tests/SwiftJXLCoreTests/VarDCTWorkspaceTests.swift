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
        let admitted = operation.reservedWorkspaceBytes
        cancellation.cancel()
        #expect(throws: CancellationError.self) {
            try pixels.withUnsafeBufferPointer { try plan.apply($0, identifier: 1, workspace: &scratch) }
        }
        #expect(operation.reservedWorkspaceBytes == admitted)
        for i in 0..<64 { #expect(scratch.value(at: i) == before[i]) }
    }
}
