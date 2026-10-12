// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct AnimationFrameIndexTests {
    private func budget(_ maximum: Int = 64 * 1024 * 1024,
                        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(30))) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: maximum,
            maximumMemoryBytes: maximum, maximumDecodedBytes: maximum,
            maximumCompressedBytes: maximum, deadline: deadline)
    }
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "jxl", subdirectory: "VarDCT/Animation")))
    }
    @Test(arguments: ["libjxl-lossless", "libjxl-lossy"])
    func independentAnimationIndex(_ name: String) throws {
        let data = try fixture(name)
        let index = try AnimationFrameIndex.read(data, budget: budget(), maximumFrames: 3)
        #expect(index.image.width == 16 && index.image.height == 9)
        #expect(index.animation?.tpsNumerator == 100 && index.animation?.tpsDenominator == 1)
        #expect(index.animation?.numLoops == 3)
        #expect(index.frames.map(\.duration) == [10, 20, 30])
        #expect(index.frames.map(\.startTick) == [0, 10, 30] && index.totalTicks == 60)
        #expect(index.frames.map { $0.header.isLast } == [false, false, true])
        #expect(index.frames.allSatisfy { $0.header.encoding == (name == "libjxl-lossless" ? .modular : .varDCT) })
        var end = index.preludeRange.upperBound
        for i in 0..<3 {
            let entry = try index.frame(at: i)
            if name == "libjxl-lossless" { _ = try index.standaloneFrame(at: i) }
            #expect(entry.frameRange.lowerBound == end)
            #expect(entry.payloadRange.lowerBound >= entry.frameRange.lowerBound)
            #expect(entry.payloadRange.upperBound == entry.frameRange.upperBound)
            #expect(!data.subdata(in: entry.frameRange).isEmpty)
            end = entry.frameRange.upperBound
        }
        #expect(end == data.count)
        #expect(throws: ScalarModularError.self) { _ = try index.frame(at: -1) }
        #expect(throws: ScalarModularError.self) { _ = try index.frame(at: 3) }
        var wrapped = Data([0, 0, 0, 12, 0x4a, 0x58, 0x4c, 0x20, 13, 10, 135, 10])
        wrapped.append(Data([0, 0, 0, 20])); wrapped.append(Data("ftypjxl ".utf8))
        wrapped.append(Data([0, 0, 0, 0])); wrapped.append(Data("jxl ".utf8))
        let size = UInt32(data.count + 8)
        wrapped.append(contentsOf: [UInt8(size >> 24), UInt8(truncatingIfNeeded: size >> 16),
            UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)])
        wrapped.append(Data("jxlc".utf8)); wrapped.append(data)
        let boxed = try AnimationFrameIndex.read(wrapped, budget: budget(), maximumFrames: 3)
        #expect(boxed.frames.map(\.frameRange) == index.frames.map(\.frameRange))
    }
    @Test(arguments: ["libjxl-lossless", "libjxl-lossy"])
    func truncationAndLimits(_ name: String) throws {
        let data = try fixture(name)
        // Every byte boundary, including selected-frame truncated TOCs, must throw.
        for length in 0..<data.count {
            #expect(throws: (any Error).self) {
                _ = try AnimationFrameIndex.read(Data(data.prefix(length)), budget: budget(), maximumFrames: 3)
            }
        }
        #expect(throws: ScalarModularError.self) {
            _ = try AnimationFrameIndex.read(data, budget: budget(), maximumFrames: 2)
        }
        #expect(throws: ScalarModularError.self) {
            _ = try AnimationFrameIndex.read(data, budget: budget(), maximumFrames: 3, maximumTotalTicks: 59)
        }
        #expect(throws: ScalarModularError.self) {
            _ = try AnimationFrameIndex.read(data, budget: budget(), maximumFrames: 0)
        }
        #expect(throws: ScalarModularError.self) {
            _ = try AnimationFrameIndex.read(data, budget: budget(1), maximumFrames: 3)
        }
        #expect(throws: ScalarModularError.self) {
            _ = try AnimationFrameIndex.read(data, budget: budget(deadline: .now.advanced(by: .seconds(-1))), maximumFrames: 3)
        }
        #expect(throws: ScalarModularError.self) {
            _ = try AnimationFrameIndex.read(data + Data([0]), budget: budget(), maximumFrames: 3)
        }
    }
    /// Header-only synthetic fixtures deliberately do not contain valid pixels:
    /// the index promises structural admission, not pixel payload validation.
    private func synthetic(durations: [UInt32] = [10, 20], numerator: UInt32 = 100,
                           denominator: UInt32 = 1, timecodes: Bool = false,
                           reference: UInt32 = 0, last: Bool = true,
                           declaredSize: UInt32 = 1, animation: Bool = true) throws -> Data {
        var w = BitWriter()
        w.write(bits: 8, value: 0xff); w.write(bits: 8, value: 0x0a)
        try SizeHeader(xsize: 16, ysize: 9).write(to: &w)
        let meta = ImageMetadata(allDefault: false, orientation: 1, intrinsicSize: nil, preview: nil,
            animation: animation ? AnimationHeader(tpsNumerator: numerator, tpsDenominator: denominator,
                numLoops: 0, haveTimecodes: timecodes) : nil,
            bitDepth: BitDepth(floatingPoint: false, bitsPerSample: 8), modular16BitBufferSufficient: true,
            extraChannels: [], xybEncoded: false, colorEncoding: .srgb,
            intensityTarget: 255, minNits: 0, relativeToMaxDisplay: false, linearBelow: 0)
        try meta.write(to: &w); w.writeBit(true); w.alignToByte()
        for (i, duration) in durations.enumerated() {
            let frame = FrameHeader(allDefault: false, encoding: .modular, colorTransform: .none,
                animationFrame: AnimationFrame(duration: duration), isLast: last && i == durations.count - 1,
                saveAsReference: reference, loopFilter: .init(allDefault: false, gab: false, epfIters: 0))
            try frame.write(to: &w, context: .init(xybEncoded: false, haveAnimation: animation, haveTimecodes: timecodes))
            try TOC(hasPermutation: false, entrySizes: [declaredSize], offsets: [0, UInt64(declaredSize)]).write(to: &w)
            w.write(bits: 8, value: 0)
        }
        return w.finishToData()
    }
    @Test func malformedAndUnsupportedHeaders() throws {
        for data in try [synthetic(last: false), synthetic(declaredSize: 100000)] {
            #expect(throws: (any Error).self) { _ = try AnimationFrameIndex.read(data, budget: budget(), maximumFrames: 3) }
        }
        for data in try [synthetic(durations: [0, 20]), synthetic(timecodes: true), synthetic(reference: 1), synthetic(animation: false)] {
            #expect(throws: ScalarModularError.self) { _ = try AnimationFrameIndex.read(data, budget: budget(), maximumFrames: 3) }
        }
        let still = try AnimationFrameIndex.read(synthetic(durations: [0], animation: false), budget: budget())
        #expect(still.frames.count == 1 && still.animation == nil && still.totalTicks == 0)
        let maximum = try AnimationFrameIndex.read(synthetic(durations: [255, 255]), budget: budget(), maximumFrames: 2)
        #expect(maximum.totalTicks == 510)
    }
}
