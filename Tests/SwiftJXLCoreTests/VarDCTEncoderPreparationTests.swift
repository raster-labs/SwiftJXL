// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTEncoderPreparationTests {
    private func budget(_ maximum: Int = 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: maximum,
            maximumMemoryBytes: maximum, maximumDecodedBytes: maximum,
            maximumCompressedBytes: maximum, deadline: .now.advanced(by: .seconds(30)))
    }
    @Test func pinnedIndependentPrefilter() throws {
        let url = try #require(Bundle.module.url(forResource: "inverse-gaborish", withExtension: "f32", subdirectory: "VarDCT/Encoder"))
        let oracle = try Data(contentsOf: url)
        var offset = 0
        for (width,height) in [(1,1),(2,3),(7,5),(8,8),(17,9)] {
            for pattern in 0..<3 { for c in 0..<3 {
                let input: [Float] = (0..<(width * height)).map { i in
                    let x = i % width, y = i / width
                    return pattern == 0 ? 0.375 : pattern == 1 ? (x == 0 && y == 0 ? 1 : 0) : Float((x * 17 + y * 11 + c * 7) % 29 - 14) / 31
                }
                let actual = try VarDCTEncoderPreparation.inverseGaborish(input, width: width, height: height, budget: budget())
                for value in actual {
                    let bits = oracle.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
                    let expected = Float(bitPattern: UInt32(littleEndian: bits)); offset += 4
                    #expect(abs(value - expected) <= 0.000002 + 0.000002 * abs(expected))
                }
            } }
        }
        #expect(offset == oracle.count)
    }
    @Test func invalidPrefilterAndAdmission() throws {
        #expect(throws: VarDCTError.invalidTransform) { try VarDCTEncoderPreparation.inverseGaborish([], width: 0, height: 1, budget: budget()) }
        #expect(throws: VarDCTError.invalidTransform) { try VarDCTEncoderPreparation.inverseGaborish([0], width: 2, height: 2, budget: budget()) }
        #expect(throws: VarDCTError.nonFiniteSample) { try VarDCTEncoderPreparation.inverseGaborish([.nan], width: 1, height: 1, budget: budget()) }
        #expect(throws: (any Error).self) { try VarDCTEncoderPreparation.inverseGaborish([0], width: 1, height: 1, budget: budget(1)) }
    }
    @Test func adaptiveQuantisationAnchors() throws {
        let smooth = [[Float]](repeating: [Float](repeating: 0.25, count: 64), count: 3)
        #expect(try VarDCTEncoderPreparation.quantisation(smooth, distance: 1) == 5)
        let alternating: [Float] = (0..<64).map { $0 % 2 == 0 ? 0 : 0.5 }
        let patch = [alternating,alternating,alternating]
        #expect(try VarDCTEncoderPreparation.quantisation(patch, distance: 1) == 24)
        #expect(try VarDCTEncoderPreparation.quantisation(patch, distance: 4) == 6)
        #expect(try VarDCTEncoderPreparation.quantisation(patch, distance: 0.5) == 48)
    }
}
