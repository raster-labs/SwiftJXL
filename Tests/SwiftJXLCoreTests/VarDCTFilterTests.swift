// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTFilterTests {
    private func budget(_ workspace: Int = 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: workspace,
            maximumMemoryBytes: workspace, maximumDecodedBytes: workspace,
            maximumCompressedBytes: workspace, deadline: .now.advanced(by: .seconds(60)))
    }

    @Test(arguments: [1, 2, 9, 17], [1, 2, 8])
    func visibleBoundaryIgnoresPadding(_ width: Int, _ height: Int) throws {
        let stride = ((width + 7) / 8) * 8
        let tight = (0..<(width * height)).map { Float(($0 * 71) % 257) / 256 }
        // NaN padding makes any accidental read observable, including 1×1.
        var padded = [Float](repeating: .nan, count: stride * (height + 8))
        for y in 0..<height { for x in 0..<width { padded[y * stride + x] = tight[y * width + x] } }
        let result = try Gaborish.apply(padded, width: width, height: height, stride: stride, budget: budget())
        let w1 = Double(Gaborish.defaultWeight1), w2 = Double(Gaborish.defaultWeight2)
        let divisor = 1 + 4 * (w1 + w2)
        for y in 0..<height { for x in 0..<width {
            var expected = 0.0
            for dy in -1...1 { for dx in -1...1 {
                let coefficient = dx == 0 && dy == 0 ? 1 : (dx == 0 || dy == 0 ? w1 : w2)
                let xx = min(width - 1, max(0, x + dx)), yy = min(height - 1, max(0, y + dy))
                expected += Double(tight[yy * width + xx]) * coefficient / divisor
            } }
            #expect(abs(Double(result[y * width + x]) - expected) < 0.000001)
        } }
    }

    @Test func customWeightsAndResourceBounds() throws {
        let samples: [Float] = [1, 2, 3, 4]
        let b = try budget(16)
        #expect(try Gaborish.apply(samples, width: 2, height: 2, stride: 2, weight1: 0, weight2: 0, budget: b) == samples)
        #expect(b.reservedWorkspaceBytes == 16)
        #expect(throws: (any Error).self) { try Gaborish.apply(samples, width: 2, height: 2, stride: 2, budget: budget(15)) }
        for dimensions in [(0, 2, 2), (2, 2, 1), (Int.max, 2, Int.max), (2, Int.max, 2)] {
            #expect(throws: (any Error).self) {
                try Gaborish.apply(samples, width: dimensions.0, height: dimensions.1, stride: dimensions.2, budget: budget())
            }
        }
        for weight: Float in [.nan, .infinity, -1] {
            #expect(throws: (any Error).self) { try Gaborish.apply(samples, width: 2, height: 2, stride: 2, weight1: weight, budget: budget()) }
        }
        #expect(throws: (any Error).self) { try Gaborish.apply([Float.nan], width: 1, height: 1, stride: 1, budget: budget()) }
    }
}
