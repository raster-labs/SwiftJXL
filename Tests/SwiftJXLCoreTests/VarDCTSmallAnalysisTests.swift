// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTSmallAnalysisTests {
    private func budget(_ maximum: Int = 16 * 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: maximum,
            maximumMemoryBytes: maximum, maximumDecodedBytes: maximum,
            maximumCompressedBytes: maximum, deadline: .now.advanced(by: .seconds(30)))
    }
    @Test(arguments: [0,1,2,3,12,13,14,15,16,17])
    func pinnedIndependentForwardBasis(_ identifier: Int) throws {
        let ids = [0,1,2,3,12,13,14,15,16,17]
        let index = try #require(ids.firstIndex(of: identifier))
        let url = try #require(Bundle.module.url(forResource: "small-forward", withExtension: "f32", subdirectory: "VarDCT/Encoder"))
        let oracle = try Data(contentsOf: url), operation = try budget()
        let plan = try VarDCTSmallAnalysis(budget: operation)
        for basis in 0..<65 {
            let input: [Float] = (0..<64).map { basis < 64 ? ($0 == basis ? 1 : 0) : Float(($0 * 17 % 29) - 14) / 31 }
            let actual = try plan.apply(input, identifier: identifier)
            for k in 0..<64 {
                let offset = ((index * 65 + basis) * 64 + k) * 4
                let bits = oracle.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
                let expected = Float(bitPattern: UInt32(littleEndian: bits))
                #expect(abs(actual[k] - expected) <= 0.000002 + 0.000002 * abs(expected))
            }
            let pixels: [Float]
            if identifier == 0 {
                var normal = [Float](repeating: 0, count: 64)
                for y in 0..<8 { for x in 0..<8 { normal[y * 8 + x] = actual[x * 8 + y] } }
                pixels = try ScaledDCT(rows: 8, columns: 8, direction: .inverse, budget: operation).apply(normal)
            } else if identifier >= 14 {
                pixels = try VarDCTAFV.inverse(actual, kind: identifier - 14, budget: operation)
            } else {
                pixels = try VarDCTSmallTransforms.inverse(actual, identifier: identifier, budget: operation)
            }
            for k in 0..<64 { #expect(abs(pixels[k] - input[k]) <= 0.000002) }
        }
    }
    @Test func invalidAndCumulativeAdmission() throws {
        let operation = try budget(16 * 1024), plan = try VarDCTSmallAnalysis(budget: operation)
        #expect(throws: VarDCTError.invalidTransform) { try plan.apply([], identifier: 0) }
        #expect(throws: VarDCTError.invalidTransform) { try plan.apply([Float](repeating: 0, count: 64), identifier: 21) }
        #expect(throws: VarDCTError.nonFiniteSample) { try plan.apply([Float](repeating: .infinity, count: 64), identifier: 0) }
        #expect(throws: (any Error).self) {
            for _ in 0..<10 { _ = try plan.apply([Float](repeating: 0, count: 64), identifier: 0) }
        }
    }
}
