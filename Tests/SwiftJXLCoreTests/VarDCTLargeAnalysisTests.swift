// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTLargeAnalysisTests {
    private func budget(_ maximum: Int = 16 * 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: maximum,
            maximumMemoryBytes: maximum, maximumDecodedBytes: maximum,
            maximumCompressedBytes: maximum, deadline: .now.advanced(by: .seconds(30)))
    }
    @Test func independentLargeTransformsAndDC() throws {
        let url = try #require(Bundle.module.url(forResource: "large-forward", withExtension: "f32", subdirectory: "VarDCT/Encoder"))
        let oracle = try Data(contentsOf: url), operation = try budget()
        var offset = 0
        for id in [4,5,6,7,8,9,10,11,18,19,20] {
            let plan = try VarDCTLargeAnalysis(identifier: id, budget: operation)
            let width = plan.columns, height = plan.rows
            for pattern in 0..<4 {
                let input: [Float] = (0..<(width * height)).map { i in
                    let x = i % width, y = i / width
                    switch pattern {
                    case 0: return 0.375
                    case 1: return x == 0 && y == 0 ? 1 : 0
                    case 2: return x == width / 2 && y == height / 2 ? 1 : 0
                    default: return Float((x * 17 + y * 11) % 29 - 14) / 31
                    }
                }
                let result = try plan.apply(input)
                for values in [result.coefficients,result.dc] { for actual in values {
                    let bits = oracle.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
                    let expected = Float(bitPattern: UInt32(littleEndian: bits)); offset += 4
                    #expect(abs(actual - expected) <= 0.000002 + 0.000002 * abs(expected))
                } }
            }
        }
        #expect(offset == oracle.count)
    }
    @Test func unsupportedAndExhausted() throws {
        #expect(throws: VarDCTError.unsupportedStrategy(21)) { try VarDCTLargeAnalysis(identifier: 21, budget: budget()) }
        #expect(throws: (any Error).self) { try VarDCTLargeAnalysis(identifier: 18, budget: budget(1)) }
        let plan = try VarDCTLargeAnalysis(identifier: 4, budget: budget())
        #expect(throws: VarDCTError.invalidTransform) { try plan.apply([]) }
        #expect(throws: VarDCTError.nonFiniteSample) { try plan.apply([Float](repeating: .nan, count: 256)) }
    }
}
