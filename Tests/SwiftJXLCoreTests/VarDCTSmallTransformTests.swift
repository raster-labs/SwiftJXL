// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTSmallTransformTests {
    private func budget(_ bytes: Int = 4 * 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: bytes,
            maximumMemoryBytes: bytes, maximumDecodedBytes: bytes,
            maximumCompressedBytes: bytes, deadline: .now.advanced(by: .seconds(30)))
    }
    @Test(arguments: [1,2,3,12,13,14,15,16,17])
    func independentImpulseBasisAndPattern(_ identifier: Int) throws {
        let ids = [1,2,3,12,13,14,15,16,17]
        let slot = try #require(ids.firstIndex(of: identifier))
        let url = try #require(Bundle.module.url(forResource: "small-transform-basis", withExtension: "f32le", subdirectory: "VarDCT"))
        let data = try Data(contentsOf: url)
        #expect(data.count == 9 * 65 * 64 * 4)
        let admission = try budget()
        for vector in 0..<65 {
            let input: [Float] = (0..<64).map { vector < 64 ? ($0 == vector ? 1 : 0) : Float(($0 * 17 % 29) - 14) / 31 }
            let actual = try identifier >= 14 ? VarDCTAFV.inverse(input, kind: identifier - 14, budget: admission)
                : VarDCTSmallTransforms.inverse(input, identifier: identifier, budget: admission)
            for i in 0..<64 {
                let offset = ((slot * 65 + vector) * 64 + i) * 4
                let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
                let expected = Float(bitPattern: UInt32(littleEndian: raw))
                #expect(abs(actual[i] - expected) <= 0.000002 + 0.000002 * abs(expected))
            }
        }
    }
    @Test func invalidAndResourceBoundaries() throws {
        let zero = [Float](repeating: 0, count: 64)
        #expect(throws: (any Error).self) { try VarDCTAFV.inverse(zero, kind: 4, budget: budget()) }
        #expect(throws: (any Error).self) { try VarDCTAFV.inverse([], kind: 0, budget: budget()) }
        #expect(throws: (any Error).self) { try VarDCTAFV.inverse(zero, kind: 0, budget: budget(1)) }
        for id in [1,2,3,12,13] {
            #expect(throws: (any Error).self) { try VarDCTSmallTransforms.inverse(zero, identifier: id, budget: budget(1)) }
            var invalid = zero; invalid[63] = .infinity
            #expect(throws: (any Error).self) { try VarDCTSmallTransforms.inverse(invalid, identifier: id, budget: budget()) }
        }
    }
}
