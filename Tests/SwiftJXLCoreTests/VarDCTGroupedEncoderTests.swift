// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTGroupedEncoderTests {
    private func budget(_ bytes: Int = 1024 * 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: bytes,
            maximumMemoryBytes: bytes, maximumDecodedBytes: bytes,
            maximumCompressedBytes: min(bytes, 32 * 1024 * 1024), deadline: .now.advanced(by: .seconds(120)))
    }
    private func fixture(_ name: String, _ suffix: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: suffix,
            subdirectory: "VarDCT/GroupedEncoder"))
        return try Data(contentsOf: url)
    }
    private func source(_ w: Int, _ h: Int, _ channels: Int, _ bits: Int) -> Data {
        let step = bits / 8
        var input = Data(count: w * h * channels * step)
        for y in 0..<h { for x in 0..<w { for c in 0..<channels {
            let value = channels % 2 == 0 && c == channels - 1 ? (x * 17 + y * 31) % 256 : (x / 8 + y / 8 + c * 37) % 256
            let sample = value * (bits == 16 ? 257 : 1), i = ((y * w + x) * channels + c) * step
            input[i] = UInt8(sample & 255)
            if step == 2 { input[i + 1] = UInt8(sample >> 8) }
        } } }
        return input
    }
    private func layouts(_ w: Int, _ h: Int, _ channels: Int, _ bits: Int) throws -> [ModularChannelLayout] {
        try (0..<channels).map { try ModularChannelLayout(width: w, height: h, offset: $0 * (bits / 8),
            rowBytes: w * channels * (bits / 8), pixelStride: channels * (bits / 8), storageBits: bits, littleEndian: true) }
    }
    @Test(arguments: ["encgroup-257-17-4-8-0", "encgroup-17-257-2-16-0", "encgroup-257-259-4-8-0",
                      "encgroup-2057-9-3-8-0", "encgroup-9-2057-1-16-0", "encgroup-2057-9-4-16-1",
                      "encgroup-4096-9-4-8-0", "encgroup-9-4096-2-16-1"])
    func independentGroupedWriter(_ name: String) throws {
        let parts = name.split(separator: "-").dropFirst().compactMap { Int($0) }
        let w = parts[0], h = parts[1], channels = parts[2], bits = parts[3], large = parts[4] == 1, step = bits / 8
        let input = source(w, h, channels, bits), layout = try layouts(w, h, channels, bits)
        let original = input, audit = ScalarStorageAudit()
        let encoded = try ScalarStorageAudit.$current.withValue(audit) {
            try input.withUnsafeBytes { try VarDCTPixelEncoder.encode($0, layouts: layout, bitsPerSample: bits,
                grayscale: channels <= 2, alphaAssociated: channels % 2 == 0 ? false : nil, distance: 1,
                gaborish: large, adaptiveQuantisation: large, dcSmoothing: large,
                smallStrategySearch: large, largeStrategySearch: large, budget: budget()) }
        }
        #expect(input == original)
        #expect(audit.snapshot.finalPixelAllocations == 0)
        #expect(try encoded == fixture(name, "jxl"))
        let envelope = try VarDCTFrameEnvelope.read(encoded, budget: budget())
        #expect(envelope.sectionCount == 2 + envelope.groupsX * envelope.groupsY + envelope.dcGroupsX * envelope.dcGroupsY)
        #expect(envelope.frame.flags == (large ? 0 : 128) && envelope.frame.loopFilter.gab == large)
        var pixels = Data(count: input.count)
        try pixels.withUnsafeMutableBytes { try VarDCTPixelDecoder.decode(envelope, into: $0, layouts: layout) }
        let oracle = try fixture(name, "scalar"), maximum = (1 << bits) - 1
        #expect(oracle.count == w * h * channels * 4)
        var peak = 0, squared = 0.0, count = 0, alphaExact = true
        for i in 0..<(w * h * channels) {
            let raw = oracle.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self) }
            let expected = Int((min(1, max(0, Double(Float(bitPattern: UInt32(littleEndian: raw))))) * Double(maximum)).rounded())
            let actual = Int(pixels[i * step]) | (step == 2 ? Int(pixels[i * step + 1]) << 8 : 0)
            if channels % 2 == 0 && i % channels == channels - 1 {
                let original = Int(input[i * step]) | (step == 2 ? Int(input[i * step + 1]) << 8 : 0)
                alphaExact = alphaExact && actual == original && expected == original
            } else {
                let error = abs(actual - expected); peak = max(peak, error); squared += Double(error * error); count += 1
            }
        }
        #expect(alphaExact)
        #expect(peak <= 2)
        #expect(sqrt(squared / Double(count)) <= 0.5)
    }
    @Test func groupedPlanarBorrowPreservesPadding() throws {
        let w = 17, h = 257, channels = 2, bits = 16
        let input = source(w, h, channels, bits), row = w * 2 + 7, plane = row * h + 13
        let layout = try (0..<channels).map { try ModularChannelLayout(width: w, height: h,
            offset: 11 + $0 * plane, rowBytes: row, pixelStride: 2, storageBits: bits, littleEndian: false) }
        var padded = Data(repeating: 0xA5, count: 11 + channels * plane)
        for y in 0..<h { for x in 0..<w { for c in 0..<channels {
            let from = ((y * w + x) * channels + c) * 2, to = layout[c].offset + y * row + x * 2
            padded[to] = input[from + 1]; padded[to + 1] = input[from]
        } } }
        let original = padded
        let encoded = try padded.withUnsafeBytes { try VarDCTPixelEncoder.encode($0, layouts: layout,
            bitsPerSample: bits, grayscale: true, alphaAssociated: false, distance: 1, budget: budget()) }
        #expect(padded == original)
        #expect(try encoded == fixture("encgroup-17-257-2-16-0", "jxl"))
    }
    @Test(arguments: [(4097, 1), (2049, 2049)])
    func rejectsUnqualifiedGeometry(_ geometry: (Int, Int)) throws {
        let (w, h) = geometry, input = Data(count: w * h), layout = try layouts(w, h, 1, 8)
        do {
            _ = try input.withUnsafeBytes { try VarDCTPixelEncoder.encode($0, layouts: layout, bitsPerSample: 8,
                grayscale: true, alphaAssociated: nil, distance: 1, budget: budget()) }
            Issue.record("Unqualified encoder geometry accepted")
        } catch ScalarModularError.unsupportedProfile {}
    }
    @Test func groupedWorkspaceRejects() throws {
        let input = source(257, 17, 4, 8), layout = try layouts(257, 17, 4, 8)
        do {
            _ = try input.withUnsafeBytes { try VarDCTPixelEncoder.encode($0, layouts: layout, bitsPerSample: 8,
                grayscale: false, alphaAssociated: false, distance: 1, budget: budget(100_000)) }
            Issue.record("Insufficient encoder workspace accepted")
        } catch ScalarModularError.resourceLimit {}
    }
}
