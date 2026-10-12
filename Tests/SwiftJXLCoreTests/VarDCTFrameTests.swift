// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTFrameTests {
    private func budget(_ maximum: Int = 64 * 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: maximum,
            maximumMemoryBytes: maximum, maximumDecodedBytes: maximum,
            maximumCompressedBytes: maximum, deadline: .now.advanced(by: .seconds(30)))
    }
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jxl", subdirectory: "VarDCT"))
        return try Data(contentsOf: url)
    }
    @Test(arguments: [17, 64], [1, 2, 3, 4])
    func independentAndPredecessorEnvelope(_ width: Int, _ channels: Int) throws {
        for bits in [8, 16] { for independent in [false, true] {
            let name = "pred-\(width)-\(channels)-\(bits)" + (independent ? ".independent" : "")
            let bytes = try fixture(name)
            let envelope = try VarDCTFrameEnvelope.read(bytes, budget: budget())
            #expect(envelope.width == width)
            #expect(envelope.height == (width == 17 ? 9 : 64))
            #expect(envelope.metadata.bitDepth.bitsPerSample == bits)
            #expect(envelope.metadata.extraChannels.count == (channels % 2 == 0 ? 1 : 0))
            #expect(envelope.metadata.colorEncoding.colorSpace == (channels <= 2 ? .grayscale : .rgb))
            #expect(envelope.frame.passes.numPasses == 1)
            #expect(envelope.sectionCount == 1)
            #expect(try envelope.section(0).bitsRemaining > 0)
            #expect(throws: (any Error).self) { try envelope.section(-1) }
            #expect(throws: (any Error).self) { try envelope.section(envelope.sectionCount) }
        } }
    }
    // A separate full-precision scalar oracle removes libjxl's UINT8 dither
    // and ARM reciprocal approximation. The original integer-oracle failures
    // remain in the migration evidence and are not reclassified by this test.
    @Test(arguments: [17, 64], [1, 2, 3, 4])
    func pinnedScalarNumerics(_ width: Int, _ channels: Int) throws {
        for bits in [8, 16] { for independent in [false, true] {
            let name = "pred-\(width)-\(channels)-\(bits)" + (independent ? ".independent" : "")
            let envelope = try VarDCTFrameEnvelope.read(fixture(name), budget: budget())
            let coefficients = try VarDCTCoefficients.read(envelope)
            let planes = try VarDCTReconstruction.xyb(coefficients)
            #expect(planes.count == 3)
            #expect(planes.allSatisfy { $0.count == envelope.width * envelope.height })
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "scalar-oracle", subdirectory: "VarDCT"))
            let expected = try Data(contentsOf: url), maximumSample = (1 << bits) - 1
            #expect(expected.count == envelope.width * envelope.height * channels * 4)
            var maximum = 0, squared = 0.0, count = 0
            func integer(_ sample: Double) -> Int { Int((min(1, max(0, sample)) * Double(maximumSample)).rounded()) }
            func oracle(_ index: Int) -> Int {
                let raw = expected.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self) }
                return integer(Double(Float(bitPattern: UInt32(littleEndian: raw))))
            }
            for i in planes[0].indices {
                let rgb = try DefaultOpsin.inverse((X: Double(planes[0][i]), Y: Double(planes[1][i]), B: Double(planes[2][i])))
                let values = channels <= 2 ? [rgb.R] : [rgb.R, rgb.G, rgb.B]
                for c in values.indices {
                    let linear = min(1, max(0, values[c]))
                    let value = integer(linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055)
                    let delta = abs(value - oracle(i * channels + c))
                    maximum = max(maximum, delta); squared += Double(delta * delta); count += 1
                }
                if let alpha = coefficients.alpha { #expect(Int(alpha[i]) == oracle(i * channels + channels - 1)) }
            }
            #expect(maximum <= 2)
            #expect(sqrt(squared / Double(count)) <= 0.5)
        } }
    }
    @Test(arguments: [17, 64], [2, 4])
    func alphaIsExact(_ width: Int, _ channels: Int) throws {
        for bits in [8, 16] {
            let name = "pred-\(width)-\(channels)-\(bits)"
            let coefficients = try VarDCTCoefficients.read(VarDCTFrameEnvelope.read(fixture(name + ".independent"), budget: budget()))
            let alpha = try #require(coefficients.alpha)
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "input", subdirectory: "VarDCT"))
            let source = try Data(contentsOf: url), step = bits / 8
            for i in alpha.indices {
                let offset = (i * channels + channels - 1) * step
                let expected = Int32(source[offset]) | (step == 2 ? Int32(source[offset + 1]) << 8 : 0)
                #expect(alpha[i] == expected)
            }
        }
    }
    @Test func customFilterParametersCannotBecomeDefaults() throws {
        var writer = BitWriter()
        writer.writeBit(false) // non-default
        writer.writeBit(true) // Gaborish
        writer.writeBit(true) // custom coefficients
        for _ in 0..<6 { writer.write(bits: 16, value: UInt32(floatToHalf(0.25))) }
        writer.write(bits: 2, value: 0) // no EPF
        writer.writeU64(0)
        var reader = BitReader(writer.finishToData())
        let filter = try LoopFilter.read(from: &reader, isModular: false)
        #expect(filter.hasCustomParameters)
        #expect(throws: (any Error).self) { var output = BitWriter(); try filter.write(to: &output) }
        #expect(!LoopFilter.default.hasCustomParameters)
    }
    @Test func truncatedLimitsAndTrailingInput() throws {
        let bytes = try fixture("pred-17-3-8")
        for count in [0, 1, 2, 4, 8, bytes.count - 1] {
            #expect(throws: (any Error).self) { try VarDCTFrameEnvelope.read(bytes.prefix(count), budget: budget()) }
        }
        #expect(throws: (any Error).self) { try VarDCTFrameEnvelope.read(bytes + Data([0]), budget: budget()) }
        #expect(throws: (any Error).self) { try VarDCTFrameEnvelope.read(bytes, budget: budget(1)) }
        #expect(throws: (any Error).self) { try VarDCTFrameEnvelope.read(bytes, budget: budget(), maximumDimension: 16) }
        #expect(throws: (any Error).self) { try VarDCTFrameEnvelope.read(bytes, budget: budget(), maximumPixels: 152) }
        _ = try VarDCTFrameEnvelope.read(bytes, budget: budget(), maximumDimension: 17, maximumPixels: 153)
    }
}
