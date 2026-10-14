// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import SwiftJXLCore

struct ModularLearningSampleTests {
    @Test(arguments: [1, 2, 255_999, 256_000, 256_001, 511_999, 512_000, 512_001, 16_000_000])
    func exactCountAndUniformCoverage(_ population: Int) throws {
        let plan = try ModularLearningSamples(population: population)
        let indices = Array(plan)
        let expectedCount = min(population, 256_000)
        #expect(plan.count == expectedCount)
        #expect(indices.count == expectedCount)
        // Independent rational definition; these fixture products fit Int64.
        let expected = (0..<expectedCount).map { i in
            Int(Int64(i) * Int64(population) / Int64(expectedCount))
        }
        #expect(indices == expected)
        #expect(indices.first == 0)
        #expect(indices.last! < population)
    }

    @Test func maximumIntegerPopulationDoesNotOverflow() throws {
        let plan = try ModularLearningSamples(population: Int.max)
        var count = 0, previous = -1
        let lowerGap = Int.max / 256_000
        for index in plan {
            if count == 0 { #expect(index == 0) }
            else {
                let gap = index - previous
                #expect(gap == lowerGap || gap == lowerGap + 1)
            }
            previous = index
            count += 1
        }
        let finalGap = lowerGap + (Int.max % 256_000 == 0 ? 0 : 1)
        #expect(count == 256_000)
        #expect(previous == Int.max - finalGap)
        var iterator = plan.makeIterator()
        for _ in 0..<count { _ = iterator.next() }
        #expect(iterator.next() == nil)
        #expect(iterator.next() == nil)
    }

    @Test(arguments: [0, -1, Int.min])
    func nonPositivePopulationRejects(_ population: Int) {
        #expect(throws: ScalarModularError.self) {
            try ModularLearningSamples(population: population)
        }
    }
}
