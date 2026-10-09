// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct SpecRCTTests {
    private struct Vectors: Decodable {
        struct Case: Decodable { let type: UInt32; let output: [[Int32]] }
        let input: [[Int32]]
        let cases: [Case]
    }
    @Test(arguments: UInt32(0)..<42)
    func matchesPinnedPredecessorIncludingWrappingExtremes(_ type: UInt32) throws {
        let url = try #require(Bundle.module.url(forResource: "rct-baseline", withExtension: "json", subdirectory: "Modular"))
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        let expected = try #require(vectors.cases.first { $0.type == type })
        var a = vectors.input[0], b = vectors.input[1], c = vectors.input[2]
        try SpecRCT.inverse(rctType: type, channel0: &a, channel1: &b, channel2: &c, checkpoint: {})
        #expect([a,b,c] == expected.output)
    }
    @Test func reusesUniqueWorkingPlanesAndRejectsBeforeWriting() throws {
        var a = (0..<256).map(Int32.init)
        var b = (0..<256).map { Int32($0 * 2) }
        var c = (0..<256).map { Int32($0 * 3) }
        func address(_ values: [Int32]) -> UInt {
            values.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        }
        let before = [address(a), address(b), address(c)]
        try SpecRCT.inverse(rctType: 6, channel0: &a, channel1: &b, channel2: &c, checkpoint: {})
        #expect([address(a), address(b), address(c)] == before)
        let expected = [a,b,c]
        #expect(throws: SpecRCTError.self) {
            try SpecRCT.inverse(rctType: 42, channel0: &a, channel1: &b, channel2: &c, checkpoint: {})
        }
        #expect([a,b,c] == expected)
        var short = [Int32](repeating: 9, count: 2)
        #expect(throws: SpecRCTError.self) {
            try SpecRCT.inverse(rctType: 6, channel0: &a, channel1: &b, channel2: &short, checkpoint: {})
        }
        #expect(a == expected[0] && b == expected[1] && short == [9,9])
    }
    @Test func cancellationIsBoundedAndDeadlineCallbackIsHonoured() throws {
        var a = [Int32](repeating: 10, count: 3072)
        var b = [Int32](repeating: 20, count: 3072)
        var c = [Int32](repeating: 30, count: 3072)
        var calls = 0
        #expect(throws: CancellationError.self) {
            try SpecRCT.inverse(rctType: 6, channel0: &a, channel1: &b, channel2: &c, checkpoint: {
                calls += 1
                if calls == 3 { throw CancellationError() }
            })
        }
        #expect(calls == 3)
        #expect(a.prefix(1024).allSatisfy { $0 == 5 })
        #expect(a.suffix(2048).allSatisfy { $0 == 10 })
        let expected = [a,b,c]
        #expect(throws: ScalarModularError.self) {
            try SpecRCT.inverse(rctType: 6, channel0: &a, channel1: &b, channel2: &c,
                checkpoint: { throw ScalarModularError.resourceLimit })
        }
        #expect([a,b,c] == expected)
    }
}
