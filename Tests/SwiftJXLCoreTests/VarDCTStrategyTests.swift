// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTStrategyTests {
    private func budget(_ maximum: Int = 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: maximum,
            maximumMemoryBytes: maximum, maximumDecodedBytes: maximum,
            maximumCompressedBytes: maximum, deadline: .now.advanced(by: .seconds(30)))
    }
    @Test func mixedRasterCoverage() throws {
        // One DCT16x16 plus two DCT8 blocks, occupying a 3x2 grid.
        let map = try VarDCTStrategyMap.read([4, 0, 0, 10, -1, .max], count: 3, width: 3, height: 2, budget: budget())
        #expect(map.indices == [0, 0, 1, 0, 0, 2])
        #expect(map.transforms.map(\.coefficientOffset) == [0, 256, 320])
        #expect(map.transforms.map(\.quantisation) == [11, 1, 256])
        #expect(map.coefficientCount == 384)
    }
    @Test(arguments: Array(0...26))
    func allStrategyGeometries(_ identifier: Int) throws {
        // Independent dimensions adapted from the pinned predecessor ACStrategy geometry.
        let dimensions = [(1,1),(1,1),(1,1),(1,1),(2,2),(4,4),(1,2),(2,1),(1,4),(4,1),(2,4),(4,2),(1,1),(1,1),(1,1),(1,1),(1,1),(1,1),(8,8),(4,8),(8,4),(16,16),(8,16),(16,8),(32,32),(16,32),(32,16)]
        let (width, height) = dimensions[identifier]
        let map = try VarDCTStrategyMap.read([Int32(identifier), 0], count: 1, width: width, height: height, budget: budget())
        #expect(map.indices.allSatisfy { $0 == 0 })
        #expect(map.coefficientCount == width * height * 64)
        #expect(map.transforms.count == 1)
    }
    @Test func overlapsBoundariesAndCountsReject() throws {
        // A 1x2 shape at (0,0), then a 2x2 at (1,0) would overflow width.
        #expect(throws: (any Error).self) { try VarDCTStrategyMap.read([6,4,0,0], count: 2, width: 2, height: 2, budget: budget()) }
        // A 1x2 shape at (1,0) is later overlapped from (0,1).
        #expect(throws: (any Error).self) { try VarDCTStrategyMap.read([0,6,7,0,0,0], count: 3, width: 2, height: 2, budget: budget()) }
        #expect(throws: (any Error).self) { try VarDCTStrategyMap.read([27,0], count: 1, width: 1, height: 1, budget: budget()) }
        #expect(throws: (any Error).self) { try VarDCTStrategyMap.read([0,0], count: 1, width: 2, height: 1, budget: budget()) }
        #expect(throws: (any Error).self) { try VarDCTStrategyMap.read([0,0], count: 1, width: Int.max, height: 1, budget: budget()) }
        #expect(throws: (any Error).self) { try VarDCTStrategyMap.read([0,0], count: 1, width: 1, height: 1, budget: budget(1)) }
    }
}
