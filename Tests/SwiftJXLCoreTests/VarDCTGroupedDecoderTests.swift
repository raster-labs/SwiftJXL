// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTGroupedDecoderTests {
    private func budget(_ bytes: Int = 256 * 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: bytes,
            maximumMemoryBytes: bytes, maximumDecodedBytes: bytes,
            maximumCompressedBytes: bytes, deadline: .now.advanced(by: .seconds(60)))
    }
    private func fixture(_ name: String, _ suffix: String = "jxl") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: suffix,
            subdirectory: "VarDCT/GroupedDecoder"))
        return try Data(contentsOf: url)
    }
    @Test(arguments: ["grouped-257-17-4-8", "grouped-17-257-2-16", "grouped-257-259-4-8",
                      "grouped-2057-9-3-8", "grouped-9-2057-1-16", "grouped-2057-9-4-16"])
    func independentGroupedPixels(_ name: String) throws {
        let parts = name.split(separator: "-").dropFirst().compactMap { Int($0) }
        let w = parts[0], h = parts[1], channels = parts[2], bits = parts[3], step = bits / 8
        let envelope = try VarDCTFrameEnvelope.read(fixture(name), budget: budget())
        #expect(envelope.groupsX * envelope.groupsY > 1)
        #expect(envelope.dcGroupsX * envelope.dcGroupsY == (max(w, h) > 2048 ? 2 : 1))
        let stride = w * channels * step + 7
        let layouts = try (0..<channels).map { c in
            try ModularChannelLayout(width: w, height: h, offset: 11 + c * step,
                rowBytes: stride, pixelStride: channels * step, storageBits: bits, littleEndian: true)
        }
        var storage = [UInt8](repeating: 0xA5, count: 11 + stride * h)
        let audit = ScalarStorageAudit()
        try ScalarStorageAudit.$current.withValue(audit) {
            try storage.withUnsafeMutableBytes { try VarDCTPixelDecoder.decode(envelope, into: $0, layouts: layouts) }
        }
        #expect(audit.snapshot.finalPixelAllocations == 0)
        let oracle = try fixture(name, "scalar-oracle")
        var peak = 0, squared = 0.0, colourCount = 0, alphaExact = true
        for y in 0..<h { for x in 0..<w { for c in 0..<channels {
            let index = 11 + y * stride + (x * channels + c) * step
            let actual = Int(storage[index]) + (step == 2 ? Int(storage[index + 1]) << 8 : 0)
            let raw = oracle.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: ((y * w + x) * channels + c) * 4, as: UInt32.self) }
            let expected = Int((Double(min(1, max(0, Float(bitPattern: UInt32(littleEndian: raw))))) * Double((1 << bits) - 1)).rounded())
            let error = abs(actual - expected)
            if channels % 2 == 0 && c == channels - 1 {
                let source = ((x * 17 + y * 31) % 256) * (bits == 16 ? 257 : 1)
                alphaExact = alphaExact && actual == expected && actual == source
            } else { peak = max(peak, error); squared += Double(error * error); colourCount += 1 }
        } }
            #expect(storage[(11 + y * stride + w * channels * step)..<(11 + (y + 1) * stride)].allSatisfy { $0 == 0xA5 })
        }
        #expect(storage.prefix(11).allSatisfy { $0 == 0xA5 })
        #expect(alphaExact)
        #expect(peak <= 2)
        #expect(sqrt(squared / Double(colourCount)) <= 0.5)
    }
    @Test(arguments: ["grouped-257-259-4-8", "grouped-2057-9-4-16"])
    func truncatedGroupedStreamsReject(_ name: String) throws {
        let source = try fixture(name)
        for cut in [1, source.count / 2, source.count - 1] {
            #expect(throws: (any Error).self) {
                let envelope = try VarDCTFrameEnvelope.read(Data(source.prefix(cut)), budget: budget())
                _ = try VarDCTCoefficients.read(envelope)
            }
        }
    }
    @Test func inconsistentDCPrecisionRejects() throws {
        var source = try fixture("grouped-2057-9-3-8")
        let envelope = try VarDCTFrameEnvelope.read(source, budget: budget())
        let secondDC = try envelope.section(2).data
        let range = try #require(source.range(of: secondDC))
        source[range.lowerBound] ^= 1 // extra_precision is the first two section bits
        let modified = try VarDCTFrameEnvelope.read(source, budget: budget())
        do {
            _ = try VarDCTCoefficients.read(modified)
            Issue.record("Different per-group DC precision accepted")
        } catch ScalarModularError.unsupportedProfile {}
    }
    @Test func groupedWorkspaceRejectsBeforePublication() throws {
        do {
            let envelope = try VarDCTFrameEnvelope.read(fixture("grouped-257-259-4-8"), budget: budget(100_000))
            _ = try VarDCTCoefficients.read(envelope)
            Issue.record("Insufficient workspace accepted")
        } catch ScalarModularError.resourceLimit {}
    }
}
