// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL
@testable import SwiftJXLCore

/// Both historical gates stay mandatory: this suite checks the explicit integer
/// compatibility profile; the existing scalar suites keep their original path.
struct VarDCTARMIntegerTests {
    private static let cases: [String] = [
        "VarDCT|pred-17-1-16.independent|oracle",
        "VarDCT|pred-17-1-16|oracle",
        "VarDCT|pred-17-1-8.independent|oracle",
        "VarDCT|pred-17-1-8|oracle",
        "VarDCT|pred-17-2-16.independent|oracle",
        "VarDCT|pred-17-2-16|oracle",
        "VarDCT|pred-17-2-8.independent|oracle",
        "VarDCT|pred-17-2-8|oracle",
        "VarDCT|pred-17-3-16.independent|oracle",
        "VarDCT|pred-17-3-16|oracle",
        "VarDCT|pred-17-3-8.independent|oracle",
        "VarDCT|pred-17-3-8|oracle",
        "VarDCT|pred-17-4-16.independent|oracle",
        "VarDCT|pred-17-4-16|oracle",
        "VarDCT|pred-17-4-8.independent|oracle",
        "VarDCT|pred-17-4-8|oracle",
        "VarDCT|pred-64-1-16.independent|oracle",
        "VarDCT|pred-64-1-16|oracle",
        "VarDCT|pred-64-1-8.independent|oracle",
        "VarDCT|pred-64-1-8|oracle",
        "VarDCT|pred-64-2-16.independent|oracle",
        "VarDCT|pred-64-2-16|oracle",
        "VarDCT|pred-64-2-8.independent|oracle",
        "VarDCT|pred-64-2-8|oracle",
        "VarDCT|pred-64-3-16.independent|oracle",
        "VarDCT|pred-64-3-16|oracle",
        "VarDCT|pred-64-3-8.independent|oracle",
        "VarDCT|pred-64-3-8|oracle",
        "VarDCT|pred-64-4-16.independent|oracle",
        "VarDCT|pred-64-4-16|oracle",
        "VarDCT|pred-64-4-8.independent|oracle",
        "VarDCT|pred-64-4-8|oracle",
        "VarDCT/Encoder|enc-17-1-16|arm-integer",
        "VarDCT/Encoder|enc-17-1-8|arm-integer",
        "VarDCT/Encoder|enc-17-2-16|arm-integer",
        "VarDCT/Encoder|enc-17-2-8|arm-integer",
        "VarDCT/Encoder|enc-17-3-16|arm-integer",
        "VarDCT/Encoder|enc-17-3-8|arm-integer",
        "VarDCT/Encoder|enc-17-4-16|arm-integer",
        "VarDCT/Encoder|enc-17-4-8|arm-integer",
        "VarDCT/Encoder|enc-257-1-16|arm-integer",
        "VarDCT/Encoder|enc-257-1-8|arm-integer",
        "VarDCT/Encoder|enc-257-3-16|arm-integer",
        "VarDCT/Encoder|enc-257-3-8|arm-integer",
        "VarDCT/Encoder|enc-64-1-16|arm-integer",
        "VarDCT/Encoder|enc-64-1-8|arm-integer",
        "VarDCT/Encoder|enc-64-2-16|arm-integer",
        "VarDCT/Encoder|enc-64-2-8|arm-integer",
        "VarDCT/Encoder|enc-64-3-16|arm-integer",
        "VarDCT/Encoder|enc-64-3-8|arm-integer",
        "VarDCT/Encoder|enc-64-4-16|arm-integer",
        "VarDCT/Encoder|enc-64-4-8|arm-integer",
        "VarDCT/EncoderPrepared|enc-17-1-16|arm-integer",
        "VarDCT/EncoderPrepared|enc-17-1-8|arm-integer",
        "VarDCT/EncoderPrepared|enc-17-2-16|arm-integer",
        "VarDCT/EncoderPrepared|enc-17-2-8|arm-integer",
        "VarDCT/EncoderPrepared|enc-17-3-16|arm-integer",
        "VarDCT/EncoderPrepared|enc-17-3-8|arm-integer",
        "VarDCT/EncoderPrepared|enc-17-4-16|arm-integer",
        "VarDCT/EncoderPrepared|enc-17-4-8|arm-integer",
        "VarDCT/EncoderPrepared|enc-257-1-16|arm-integer",
        "VarDCT/EncoderPrepared|enc-257-1-8|arm-integer",
        "VarDCT/EncoderPrepared|enc-257-3-16|arm-integer",
        "VarDCT/EncoderPrepared|enc-257-3-8|arm-integer",
        "VarDCT/EncoderPrepared|enc-64-1-16|arm-integer",
        "VarDCT/EncoderPrepared|enc-64-1-8|arm-integer",
        "VarDCT/EncoderPrepared|enc-64-2-16|arm-integer",
        "VarDCT/EncoderPrepared|enc-64-2-8|arm-integer",
        "VarDCT/EncoderPrepared|enc-64-3-16|arm-integer",
        "VarDCT/EncoderPrepared|enc-64-3-8|arm-integer",
        "VarDCT/EncoderPrepared|enc-64-4-16|arm-integer",
        "VarDCT/EncoderPrepared|enc-64-4-8|arm-integer",
        "VarDCT/EncoderSmall|enc-17-1-16|arm-integer",
        "VarDCT/EncoderSmall|enc-17-1-8|arm-integer",
        "VarDCT/EncoderSmall|enc-17-2-16|arm-integer",
        "VarDCT/EncoderSmall|enc-17-2-8|arm-integer",
        "VarDCT/EncoderSmall|enc-17-3-16|arm-integer",
        "VarDCT/EncoderSmall|enc-17-3-8|arm-integer",
        "VarDCT/EncoderSmall|enc-17-4-16|arm-integer",
        "VarDCT/EncoderSmall|enc-17-4-8|arm-integer",
        "VarDCT/EncoderSmall|enc-257-1-16|arm-integer",
        "VarDCT/EncoderSmall|enc-257-1-8|arm-integer",
        "VarDCT/EncoderSmall|enc-257-3-16|arm-integer",
        "VarDCT/EncoderSmall|enc-257-3-8|arm-integer",
        "VarDCT/EncoderSmall|enc-64-1-16|arm-integer",
        "VarDCT/EncoderSmall|enc-64-1-8|arm-integer",
        "VarDCT/EncoderSmall|enc-64-2-16|arm-integer",
        "VarDCT/EncoderSmall|enc-64-2-8|arm-integer",
        "VarDCT/EncoderSmall|enc-64-3-16|arm-integer",
        "VarDCT/EncoderSmall|enc-64-3-8|arm-integer",
        "VarDCT/EncoderSmall|enc-64-4-16|arm-integer",
        "VarDCT/EncoderSmall|enc-64-4-8|arm-integer",
        "VarDCT/EncoderLarge|enc-17-1-16|arm-integer",
        "VarDCT/EncoderLarge|enc-17-1-8|arm-integer",
        "VarDCT/EncoderLarge|enc-17-2-16|arm-integer",
        "VarDCT/EncoderLarge|enc-17-2-8|arm-integer",
        "VarDCT/EncoderLarge|enc-17-3-16|arm-integer",
        "VarDCT/EncoderLarge|enc-17-3-8|arm-integer",
        "VarDCT/EncoderLarge|enc-17-4-16|arm-integer",
        "VarDCT/EncoderLarge|enc-17-4-8|arm-integer",
        "VarDCT/EncoderLarge|enc-257-1-16|arm-integer",
        "VarDCT/EncoderLarge|enc-257-1-8|arm-integer",
        "VarDCT/EncoderLarge|enc-257-3-16|arm-integer",
        "VarDCT/EncoderLarge|enc-257-3-8|arm-integer",
        "VarDCT/EncoderLarge|enc-64-1-16|arm-integer",
        "VarDCT/EncoderLarge|enc-64-1-8|arm-integer",
        "VarDCT/EncoderLarge|enc-64-2-16|arm-integer",
        "VarDCT/EncoderLarge|enc-64-2-8|arm-integer",
        "VarDCT/EncoderLarge|enc-64-3-16|arm-integer",
        "VarDCT/EncoderLarge|enc-64-3-8|arm-integer",
        "VarDCT/EncoderLarge|enc-64-4-16|arm-integer",
        "VarDCT/EncoderLarge|enc-64-4-8|arm-integer",
        "VarDCT/EncoderLarge|writer-10|arm-integer",
        "VarDCT/EncoderLarge|writer-11|arm-integer",
        "VarDCT/EncoderLarge|writer-18|arm-integer",
        "VarDCT/EncoderLarge|writer-19|arm-integer",
        "VarDCT/EncoderLarge|writer-20|arm-integer",
        "VarDCT/EncoderLarge|writer-4|arm-integer",
        "VarDCT/EncoderLarge|writer-5|arm-integer",
        "VarDCT/EncoderLarge|writer-6|arm-integer",
        "VarDCT/EncoderLarge|writer-7|arm-integer",
        "VarDCT/EncoderLarge|writer-8|arm-integer",
        "VarDCT/EncoderLarge|writer-9|arm-integer",
    ]
    private func resource(_ name: String, suffix: String, directory: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: suffix, subdirectory: directory))
        return try Data(contentsOf: url)
    }
    private func verify(_ image: Image, expected: Data) throws {
        let d = image.descriptor, channels = d.components.count, step = d.meaningfulBits / 8
        #expect(expected.count == d.width * d.height * channels * step)
        let roles: [ComponentRole] = (d.colour == .greyscale ? [.grey] : [.red, .green, .blue])
            + (d.alpha == .absent ? [] : [.alpha])
        var maximum = 0, squared = 0.0, colours = 0
        try image.storage.withUnsafeBytes { bytes in
            for y in 0..<d.height { for x in 0..<d.width { for c in 0..<channels {
                let component = try #require(d.components.firstIndex(of: roles[c]))
                let plane = try #require(d.planes.first { $0.components.contains(component) })
                let slot = try #require(plane.components.firstIndex(of: component))
                let offset = plane.offset + y * plane.rowBytes + x * plane.pixelStride + slot * plane.sampleStride
                let actual: Int
                if d.storageBits == 8 { actual = Int(bytes[offset]) }
                else if d.byteOrder == .littleEndian { actual = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
                else { actual = Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
                let i = ((y * d.width + x) * channels + c) * step
                let reference = Int(expected[i]) | (step == 2 ? Int(expected[i + 1]) << 8 : 0)
                let delta = abs(actual - reference)
                if roles[c] == .alpha { #expect(delta == 0) }
                else { maximum = max(maximum, delta); squared += Double(delta * delta); colours += 1 }
            } } }
        }
        #expect(maximum <= 2)
        #expect(sqrt(squared / Double(colours)) <= 0.5)
    }

    @Test(arguments: cases)
    func retainedHistoricalIntegerOracle(_ identifier: String) async throws {
        let parts = identifier.split(separator: "|").map(String.init)
        let data = try resource(parts[1], suffix: "jxl", directory: parts[0])
        let oracle = try resource(parts[1], suffix: parts[2], directory: parts[0])
        let decoder = try Decoder(configuration: .init(varDCTNumericalProfile: .libjxl012ARMInteger))
        let result = try await decoder.decode(data)
        #expect(result.report.fidelity == .lossy)
        #expect(result.report.copyEvents.isEmpty)
        try verify(result.image, expected: oracle)
    }

    @Test(arguments: [8, 16], [1, 2, 3, 4])
    func compatibilityCallerDestination(_ bits: Int, _ channels: Int) async throws {
        let name = "pred-17-\(channels)-\(bits).independent"
        let data = try resource(name, suffix: "jxl", directory: "VarDCT")
        let oracle = try resource(name, suffix: "oracle", directory: "VarDCT")
        let decoder = try Decoder(configuration: .init(varDCTNumericalProfile: .libjxl012ARMInteger))
        let info = try decoder.inspect(data), width = 17, height = 9
        // Eight-bit logical output deliberately stored in UInt16: selection
        // must follow meaningful precision, not the storage element width.
        let row = width * channels * 2 + 6, total = row * height + 10
        let plane = try PlaneDescriptor(width: width, height: height, components: Array(0..<channels),
            offset: 4, sampleStride: 2, pixelStride: channels * 2, rowBytes: row, byteCount: total)
        let descriptor = try ImageDescriptor(width: width, height: height, storageBits: 16,
            meaningfulBits: bits, byteOrder: .bigEndian, components: info.descriptor.components,
            colour: info.descriptor.colour, alpha: info.descriptor.alpha, planes: [plane])
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        let result = try await decoder.decode(data, into: destination, options: .init(copyPolicy: .requireSharedStorage))
        #expect(result.image.storage.allocationID == destination.storage.allocationID)
        #expect(result.report.copyEvents.isEmpty)
        try verify(result.image, expected: oracle)
        try result.image.storage.withUnsafeBytes { bytes in
            for i in bytes.indices {
                let local = i - 4
                let written = local >= 0 && local / row < height && local % row < width * channels * 2
                if !written { #expect(bytes[i] == 0) }
            }
        }
    }

    @Test func defaultProfileRemainsScalarAndSelectionIsEffective() async throws {
        #expect(DecoderConfiguration().varDCTNumericalProfile == .scalarNearest)
        let data = try resource("writer-4", suffix: "jxl", directory: "VarDCT/EncoderLarge")
        let defaultResult = try await Decoder().decode(data)
        let explicit = try await Decoder(configuration: .init(varDCTNumericalProfile: .scalarNearest)).decode(data)
        let arm = try await Decoder(configuration: .init(varDCTNumericalProfile: .libjxl012ARMInteger)).decode(data)
        func contents(_ image: Image) throws -> Data { try image.storage.withUnsafeBytes { Data($0) } }
        #expect(try contents(defaultResult.image) == contents(explicit.image))
        #expect(try contents(defaultResult.image) != contents(arm.image))
    }

    @Test func reciprocalMatchesRetainedIndependentHardware() throws {
        let data = try resource("reciprocal-bits", suffix: "txt", directory: "VarDCT/ARMInteger")
        let text = try #require(String(data: data, encoding: .utf8))
        let values = try text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").map {
            try #require(UInt32($0))
        }
        #expect(values.count == 257)
        for q in 2..<values.count {
            #expect(VarDCTReferenceNumerics.reciprocalEstimate(Int32(q)).bitPattern == values[q])
            #expect(VarDCTReferenceNumerics.reciprocalEstimate(-Int32(q)).bitPattern == values[q] | 0x80000000)
        }
    }

    @Test func optionalFullRangeHardwareReciprocalVectors() throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTJXL_ARM_RECIPROCAL_VECTORS"] else { return }
        let vectors = try JSONDecoder().decode([[Int64]].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(vectors.count >= 40_000)
        for vector in vectors {
            let value = try #require(Int32(exactly: vector[0]))
            let bits = try #require(UInt32(exactly: vector[1]))
            #expect(VarDCTReferenceNumerics.reciprocalEstimate(value).bitPattern == bits)
        }
    }
}
