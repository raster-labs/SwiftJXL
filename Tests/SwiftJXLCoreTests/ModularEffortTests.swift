// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct ModularEffortTests {
    @Test(arguments: [1, 31, 64], [1, 3, 4])
    func activityOnlyPassPreservesPredictorValues(_ width: Int, _ channels: Int) throws {
        let height = 17
        var planes = [[Int32]](repeating: [Int32](repeating: 0, count: width * height), count: channels)
        for channel in 0..<channels { for index in 0..<(width * height) {
            planes[channel][index] = Int32((index * 977 + channel * 131) % 131071 - 65535)
        }
        }
        let full = try SpecModularEncoder.wpGreedyPerPixel(width: width, height: height,
            channels: planes, postCfg: .raw4)
        let compact = try SpecModularEncoder.wpGreedyPerPixel(width: width, height: height,
            channels: planes, postCfg: .raw4, includeTreeProperties: false)
        #expect(compact.tokens == full.tokens)
        #expect(compact.propsFlat == stride(from: 5, to: full.propsFlat.count, by: 6).map { full.propsFlat[$0] })
        #expect(compact.tokBucket.isEmpty && compact.maxTok == 0)
        #expect(compact.propsFlat.count == width * height * channels)
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5], Array(1...9))
    func effortStreamsMatchIndependentFixtures(_ fixtureIndex: Int, _ effort: Int) throws {
        let cases: [(String, Int, Int, Int, Int)] = [
            ("gray8", 31, 17, 1, 8), ("gray16", 32, 33, 1, 16),
            ("rgb8", 31, 17, 3, 8), ("rgba16", 33, 17, 4, 16),
            ("group-rgb8", 513, 17, 3, 8), ("vertical-rgba16", 17, 513, 4, 16)
        ]
        let (name, width, height, channels, bits) = cases[fixtureIndex]
        let maximum = (1 << bits) - 1
        var planes = [[UInt16]](repeating: [UInt16](repeating: 0, count: width * height), count: channels)
        var random: UInt32 = 20261013
        for i in 0..<(width * height) { for c in 0..<channels {
            random = random &* 1664525 &+ 1013904223
            let texture = Int(random >> 8) & maximum
            let ramp = (i * 71 + (i / width) * 37 + c * 113) & maximum
            planes[c][i] = UInt16(fixtureIndex != 0 && i % width >= width / 2 ? texture : ramp)
        } }
        let encoded: Data
        switch channels {
        case 1:
            if bits == 8 {
                encoded = try SpecModularEncoder.encodeGrayscale8(width: width, height: height,
                    pixels: planes[0].map(UInt8.init), effort: effort)
            } else {
                encoded = try SpecModularEncoder.encodeGrayscale16(width: width, height: height,
                    bitsPerSample: UInt32(bits), pixels: planes[0], effort: effort)
            }
        case 3:
            encoded = try SpecModularEncoder.encodeRGB8(width: width, height: height,
                r: planes[0].map(UInt8.init), g: planes[1].map(UInt8.init), b: planes[2].map(UInt8.init), effort: effort)
        default:
            encoded = try SpecModularEncoder.encodeRGBA16(width: width, height: height,
                bitsPerSample: UInt32(bits), r: planes[0], g: planes[1], b: planes[2], a: planes[3], effort: effort)
        }
        let rung = effort <= 3 ? 3 : effort <= 7 ? 7 : effort
        let url = try #require(Bundle.module.url(forResource: "\(name)-e\(rung)", withExtension: "jxl",
            subdirectory: "Modular/Effort"))
        #expect(try encoded == Data(contentsOf: url))
        let budget = try ScalarOperationBudget(retainedBytes: encoded.count,
            maximumWorkspaceBytes: 256 * 1024 * 1024, maximumMemoryBytes: 512 * 1024 * 1024,
            maximumDecodedBytes: 16 * 1024 * 1024, maximumCompressedBytes: 16 * 1024 * 1024,
            deadline: .now.advanced(by: .seconds(120)))
        let decoded = try ModularFrameDecoder.decode(encoded, budget: budget)
        #expect(decoded.image.channels.map(\.pixels) == planes.map { $0.map(Int32.init) })
    }

    @Test(arguments: [false, true])
    func propertyPassRejectsCancelledOrExpiredWork(_ allProperties: Bool) throws {
        let planes = [[Int32]](repeating: [Int32](repeating: 0, count: 256), count: 3)
        let cancellation = ScalarOperationCancellation()
        func context(expired: Bool) throws -> ScalarEncodingWork {
            let budget = try ScalarOperationBudget(retainedBytes: 0,
                maximumWorkspaceBytes: 1024 * 1024, maximumMemoryBytes: 2 * 1024 * 1024,
                maximumDecodedBytes: 1024 * 1024, maximumCompressedBytes: 1024 * 1024,
                deadline: .now.advanced(by: .seconds(expired ? -1 : 30)), cancellation: cancellation)
            return ScalarEncodingWork(budget: budget, writerByteLimit: 1024)
        }
        let expired = try context(expired: true)
        do {
            _ = try ScalarEncodingWork.$current.withValue(expired) {
                try SpecModularEncoder.wpGreedyPerPixel(width: 16, height: 16,
                    channels: planes, postCfg: .raw4, includeTreeProperties: allProperties)
            }
            Issue.record("Expired property pass succeeded")
        } catch ScalarModularError.resourceLimit {}
        let cancelled = try context(expired: false)
        cancellation.cancel()
        #expect(throws: CancellationError.self) {
            try ScalarEncodingWork.$current.withValue(cancelled) {
                try SpecModularEncoder.wpGreedyPerPixel(width: 16, height: 16,
                    channels: planes, postCfg: .raw4, includeTreeProperties: allProperties)
            }
        }
    }
}
