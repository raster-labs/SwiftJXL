// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import SwiftJXLCore

struct HybridUintEncodingTests {
    @Test(arguments: 0...30)
    func unfoldedTokensPreserveBitClassesAndRoundTrip(_ splitExponent: Int) throws {
        let config = HybridUintConfig(splitExponent: splitExponent)
        var values = Array(UInt32(0)...UInt32(1024))
        for bit in 0..<32 {
            let boundary = UInt32(1) << bit
            values.append(contentsOf: [boundary - 1, boundary, boundary + 1])
        }
        values.append(.max)
        var seed: UInt32 = 20261013
        for _ in 0..<256 {
            seed = seed &* 1664525 &+ 1013904223
            values.append(seed)
        }
        for value in values {
            let encoded = config.encode(value)
            // The token-only path retains the general folding formula.
            #expect(encoded.token == config.tokenOnly(value))
            let expectedBits = value < (UInt32(1) << splitExponent)
                ? 0 : 31 - value.leadingZeroBitCount
            #expect(encoded.extraNBits == expectedBits)
            var writer = BitWriter()
            writer.write(bits: encoded.extraNBits, value: encoded.extraBits)
            var reader = BitReader(writer.finishToData())
            #expect(try config.decode(token: encoded.token, from: &reader) == value)
        }
    }
}
