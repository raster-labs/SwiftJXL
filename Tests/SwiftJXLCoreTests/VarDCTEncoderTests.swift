// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTEncoderTests {
    private func budget(_ maximum: Int = 64 * 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: maximum,
            maximumMemoryBytes: maximum, maximumDecodedBytes: maximum,
            maximumCompressedBytes: maximum, deadline: .now.advanced(by: .seconds(30)))
    }
    private func fixture(_ name: String, extension suffix: String, encoder: Bool = true, prepared: Bool = false, small: Bool = false) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: suffix,
            subdirectory: encoder ? (small ? "VarDCT/EncoderSmall" : prepared ? "VarDCT/EncoderPrepared" : "VarDCT/Encoder") : "VarDCT"))
        return try Data(contentsOf: url)
    }
    private func layouts(width: Int, height: Int, channels: Int, bits: Int) throws -> [ModularChannelLayout] {
        let step = bits / 8
        return try (0..<channels).map { try ModularChannelLayout(width: width, height: height,
            offset: $0 * step, rowBytes: width * channels * step, pixelStride: channels * step,
            storageBits: bits, littleEndian: true) }
    }
    @Test(arguments: [17,64,257], [1,2,3,4])
    func independentReferenceStreams(_ width: Int, _ channels: Int) throws {
        try verifyReference(width, channels, prepared: false)
    }
    @Test(arguments: [17,64,257], [1,2,3,4])
    func preparedReferenceStreams(_ width: Int, _ channels: Int) throws {
        try verifyReference(width, channels, prepared: true)
    }
    @Test(arguments: [17,64,257], [1,2,3,4])
    func smallStrategyReferenceStreams(_ width: Int, _ channels: Int) throws {
        try verifyReference(width, channels, prepared: true, small: true)
    }
    private func verifyReference(_ width: Int, _ channels: Int, prepared: Bool, small: Bool = false) throws {
        let height = width == 64 ? 64 : 9
        for bits in [8,16] {
            let layout = try layouts(width: width, height: height, channels: channels, bits: bits)
            if width == 257 && channels % 2 == 0 {
                let input = Data(count: width * height * channels * bits / 8)
                #expect(throws: (any Error).self) {
                    try input.withUnsafeBytes { try VarDCTPixelEncoder.encode($0, layouts: layout, bitsPerSample: bits,
                        grayscale: channels <= 2, alphaAssociated: false, distance: 1, budget: budget()) }
                }
                continue
            }
            let name = "enc-\(width)-\(channels)-\(bits)"
            let input = try width == 257 ? fixture(name, extension: "input")
                : fixture("pred-\(width)-\(channels)-\(bits)", extension: "input", encoder: false)
            let encoded = try input.withUnsafeBytes { try VarDCTPixelEncoder.encode($0, layouts: layout,
                bitsPerSample: bits, grayscale: channels <= 2, alphaAssociated: channels % 2 == 0 ? false : nil,
                distance: 1, gaborish: prepared, adaptiveQuantisation: prepared, dcSmoothing: prepared, smallStrategySearch: small, budget: budget()) }
            // Tie emitted bytes to the independently accepted libjxl corpus.
            // If encoding changes, regenerate and requalify the oracle rather
            // than claiming an old reference verifies new compressed bytes.
            #expect(try encoded == fixture(name, extension: "jxl", prepared: prepared, small: small))
            let envelope = try VarDCTFrameEnvelope.read(encoded, budget: budget())
            #expect(envelope.width == width && envelope.height == height)
            #expect(envelope.metadata.bitDepth.bitsPerSample == bits)
            #expect(envelope.frame.flags == (prepared ? 0 : 128)
                && envelope.frame.loopFilter.gab == prepared)
            var pixels = Data(count: input.count)
            try pixels.withUnsafeMutableBytes { try VarDCTPixelDecoder.decode(envelope, into: $0, layouts: layout) }
            let oracle = try fixture(name, extension: "scalar", prepared: prepared, small: small), maximum = (1 << bits) - 1, step = bits / 8
            #expect(oracle.count == width * height * channels * 4)
            var peak = 0, squared = 0.0, count = 0
            for i in 0..<(width * height * channels) {
                let raw = oracle.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self) }
                let expected = Int((min(1, max(0, Double(Float(bitPattern: UInt32(littleEndian: raw))))) * Double(maximum)).rounded())
                let actual = Int(pixels[i * step]) | (step == 2 ? Int(pixels[i * step + 1]) << 8 : 0)
                if channels % 2 == 0 && i % channels == channels - 1 {
                    let original = Int(input[i * step]) | (step == 2 ? Int(input[i * step + 1]) << 8 : 0)
                    #expect(actual == original && expected == original)
                } else {
                    let error = abs(actual - expected); peak = max(peak, error); squared += Double(error * error); count += 1
                }
            }
            #expect(peak <= 2)
            #expect(sqrt(squared / Double(count)) <= 0.5)
        }
    }

    @Test(arguments: [8,16])
    func paddedPlanarSourceIsBorrowed(_ bits: Int) throws {
        let input = try fixture("pred-17-4-\(bits)", extension: "input", encoder: false)
        let step = bits / 8, row = 17 * step + 7, plane = row * 9 + 13
        let layout = try (0..<4).map { try ModularChannelLayout(width: 17, height: 9,
            offset: 11 + $0 * plane, rowBytes: row, pixelStride: step, storageBits: bits, littleEndian: false) }
        var padded = [UInt8](repeating: 0xA5, count: 11 + 4 * plane)
        for y in 0..<9 { for x in 0..<17 { for c in 0..<4 {
            let from = ((y * 17 + x) * 4 + c) * step, to = layout[c].offset + y * row + x * step
            padded[to] = input[from + step - 1]
            if step == 2 { padded[to + 1] = input[from] }
        } } }
        let original = padded
        let encoded = try padded.withUnsafeBytes { try VarDCTPixelEncoder.encode($0, layouts: layout,
            bitsPerSample: bits, grayscale: false, alphaAssociated: false, distance: 1, budget: budget()) }
        #expect(try encoded == fixture("enc-17-4-\(bits)", extension: "jxl"))
        #expect(padded == original)
    }

    @Test func invalidPoliciesAndCumulativeAdmission() throws {
        let input = Data(repeating: 127, count: 153), layout = try layouts(width: 17, height: 9, channels: 1, bits: 8)
        for distance: Float in [0,-1,.nan,.infinity] {
            #expect(throws: (any Error).self) {
                try input.withUnsafeBytes { try VarDCTPixelEncoder.encode($0, layouts: layout, bitsPerSample: 8,
                    grayscale: true, alphaAssociated: nil, distance: distance, budget: budget()) }
            }
        }
        #expect(throws: (any Error).self) {
            try input.withUnsafeBytes { try VarDCTPixelEncoder.encode($0, layouts: layout, bitsPerSample: 8,
                grayscale: true, alphaAssociated: nil, distance: 1, budget: budget(1)) }
        }
        let operation = try budget(7 * 1024 * 1024)
        _ = try input.withUnsafeBytes { try VarDCTPixelEncoder.encode($0, layouts: layout, bitsPerSample: 8,
            grayscale: true, alphaAssociated: nil, distance: 1, budget: operation) }
        #expect(throws: (any Error).self) {
            try input.withUnsafeBytes { try VarDCTPixelEncoder.encode($0, layouts: layout, bitsPerSample: 8,
                grayscale: true, alphaAssociated: nil, distance: 1, budget: operation) }
        }
        let wide = try layouts(width: 17, height: 9, channels: 1, bits: 16)
        let excessive = Data(repeating: 255, count: 306)
        #expect(throws: (any Error).self) {
            try excessive.withUnsafeBytes { try VarDCTPixelEncoder.encode($0, layouts: wide, bitsPerSample: 12,
                grayscale: true, alphaAssociated: nil, distance: 1, budget: budget()) }
        }
        #expect(throws: (any Error).self) {
            try input.withUnsafeBytes {
                try VarDCTPixelEncoder.encode(UnsafeRawBufferPointer(rebasing: $0[..<152]), layouts: layout,
                    bitsPerSample: 8, grayscale: true, alphaAssociated: nil, distance: 1, budget: budget())
            }
        }
    }

    @Test func cancellationRejectsBeforeSourceRead() async throws {
        let layout = try layouts(width: 17, height: 9, channels: 1, bits: 8)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let input = Data(repeating: 127, count: 153)
            do {
                _ = try input.withUnsafeBytes { try VarDCTPixelEncoder.encode($0, layouts: layout,
                    bitsPerSample: 8, grayscale: true, alphaAssociated: nil, distance: 1, budget: budget()) }
                Issue.record("Cancelled encoder succeeded")
            } catch is CancellationError {}
        }
        try await task.value
    }
}
