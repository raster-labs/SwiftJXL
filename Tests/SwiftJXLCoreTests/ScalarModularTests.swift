// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct ScalarModularTests {
    @Test(arguments: [9, 10, 12, 14, 16])
    func exactPrecisionAndSamples(bits: Int) throws {
        let width = 31, height = 17
        let maximum = (Int32(1) << bits) - 1
        var samples = (0..<(width * height)).map { Int32(($0 * 7919) ^ ($0 >> 2)) & maximum }
        samples[0] = 0; samples[1] = maximum; samples[2] = 1
        let encoded = try SpecModularEncoder.encodeGrayscale16(width: width, height: height,
            bitsPerSample: UInt32(bits), pixelsInt32: samples, effort: 3)
        let decoded = try ScalarModularDecoder.decode(encoded)
        #expect(decoded.width == width)
        #expect(decoded.height == height)
        #expect(decoded.bitsPerSample == bits)
        #expect(decoded.pixels == samples)
    }

    @Test func invalidDimensionsThrow() {
        #expect(throws: (any Error).self) {
            try SpecModularEncoder.encodeGrayscale16(width: -1, height: 1, pixelsInt32: [Int32]())
        }
        #expect(throws: (any Error).self) {
            try SpecModularEncoder.encodeGrayscale16(width: 1, height: 0, pixelsInt32: [Int32]())
        }
    }
}
