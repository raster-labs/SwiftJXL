// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTEPFTests {
    private func budget(_ maximum: Int = 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: maximum,
            maximumMemoryBytes: maximum, maximumDecodedBytes: maximum,
            maximumCompressedBytes: maximum, deadline: .now.advanced(by: .seconds(30)))
    }
    @Test(arguments: [1, 2, 17], [0, 1, 2, 3])
    func constantTinyAndOddPlanes(_ width: Int, _ iterations: Int) throws {
        let height = width == 17 ? 9 : width
        let input = (0..<3).map { c in [Float](repeating: Float(c + 1) * 0.125, count: width * height) }
        let blocks = ((width + 7) / 8) * ((height + 7) / 8)
        let result = try EdgePreservingFilter.apply(input, width: width, height: height,
            iterations: iterations, quantisation: [UInt32](repeating: 1, count: blocks),
            sharpness: [Int32](repeating: 7, count: blocks), globalScale: 1, budget: budget())
        for c in 0..<3 { for i in input[c].indices { #expect(abs(input[c][i] - result[c][i]) < 0.000001) } }
    }
    @Test func disabledSharpnessAndAdmission() throws {
        let input = (0..<3).map { c in (0..<153).map { Float(($0 * 31 + c) % 127) / 126 } }
        let result = try EdgePreservingFilter.apply(input, width: 17, height: 9, iterations: 3,
            quantisation: [1, 1, 1, 1, 1, 1], sharpness: [0, 0, 0, 0, 0, 0], globalScale: 65536, budget: budget())
        #expect(result == input)
        #expect(throws: (any Error).self) {
            try EdgePreservingFilter.apply(input, width: 17, height: 9, iterations: 3,
                quantisation: [1, 1, 1, 1, 1, 1], sharpness: [0, 0, 0, 0, 0, 0], globalScale: 65536, budget: budget(1))
        }
        for sharpness: Int32 in [-1, 8] {
            #expect(throws: (any Error).self) {
                try EdgePreservingFilter.apply([[0], [0], [0]], width: 1, height: 1, iterations: 1,
                    quantisation: [1], sharpness: [sharpness], globalScale: 1, budget: budget())
            }
        }
        #expect(throws: (any Error).self) {
            try EdgePreservingFilter.apply([[.nan], [0], [0]], width: 1, height: 1, iterations: 1,
                quantisation: [1], sharpness: [0], globalScale: 1, budget: budget())
        }
        #expect(throws: (any Error).self) {
            try EdgePreservingFilter.apply([[0], [0], [0]], width: Int.max, height: 1, iterations: 1,
                quantisation: [1], sharpness: [0], globalScale: 1, budget: budget())
        }
    }
}
