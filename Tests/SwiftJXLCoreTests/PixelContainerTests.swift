// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct PixelContainerTests {
    private func image() throws -> Image {
        try ImageDestination.allocate(descriptor: .greyscale16(width: 9, height: 7))
            .writeUInt16 { x, y in UInt16((x * 1937 + y * 1211) % 65536) }
    }
    @Test(arguments: [false, true]) func explicitContainerPreservesCodestreamAndReportsCompressedCopy(_ lossy: Bool) async throws {
        let source = try image(), mode: CompressionMode = lossy ? .lossy : .lossless
        let raw = try await Encoder(configuration: .init(mode: mode)).encode(source)
        let boxed = try await Encoder(configuration: .init(mode: mode, codecOptions: .init(container: .iso))).encode(source)
        #expect(boxed.data.count == raw.data.count + 40)
        #expect(boxed.data.prefix(12) == Data(jxlContainerSignature))
        guard case .iso(let boxes) = try parseJXLContainer(boxed.data) else { Issue.record("Missing ISO container"); return }
        #expect(boxes.map(\.type) == ["ftyp", "jxlc"])
        #expect(try extractCodestream(from: boxes, in: boxed.data) == raw.data)
        #expect(raw.report.copyEvents.isEmpty)
        #expect(boxed.report.copyEvents.count == 1)
        #expect(boxed.report.copyEvents.first?.bytesMoved == raw.data.count)
        let decoder = try Decoder(), a = try await decoder.decode(raw.data), b = try await decoder.decode(boxed.data)
        #expect(try a.image.storage.withUnsafeBytes { Data($0) } == b.image.storage.withUnsafeBytes { Data($0) })
        #expect(boxed.report.fidelity == (lossy ? .lossy : .exactSamples))
        do {
            _ = try await Encoder(configuration: .init(mode: mode, codecOptions: .init(container: .iso)))
                .encode(source, options: .init(resourceLimits: .init(maximumCompressedBytes: boxed.data.count - 1)))
            Issue.record("Ignored container overhead in compressed limit")
        } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
    }
    @Test func wrapsAnimationOnlyOnceAndPreservesExactTiming() async throws {
        let frames = try [AnimationInputFrame(image: image(), durationTicks: 11), AnimationInputFrame(image: image(), durationTicks: 29)]
        let clock = try AnimationEncodingOptions(ticksPerSecondNumerator: 24000, ticksPerSecondDenominator: 1001, loopCount: 4)
        let raw = try await Encoder().encodeAnimation(frames, animation: clock)
        let wrapped = try await Encoder(configuration: .init(codecOptions: .init(container: .iso))).encodeAnimation(frames, animation: clock)
        #expect(wrapped.encoded.data.dropFirst(40) == raw.encoded.data)
        #expect(wrapped.compressedFrameBytesMaterialised == raw.compressedFrameBytesMaterialised)
        #expect(wrapped.encoded.report.copyEvents.count == 1)
        let decoded = try await Decoder().decodeAll(wrapped.encoded.data)
        #expect(decoded.frames.map(\.durationTicks) == [11, 29])
        #expect(decoded.timing == raw.timing)
        #expect(decoded.frames.count == 2)
    }
}
