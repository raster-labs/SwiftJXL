// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct AnimationEncoderTests {
    private func source(bits: Int, channels: Int, frame: Int) throws -> Image {
        let step = bits / 8, row = 16 * channels * step + 8
        let descriptor = try ImageDescriptor(width: 16, height: 9, storageBits: bits, meaningfulBits: bits,
            byteOrder: .bigEndian, components: channels == 3 ? [.red, .green, .blue] : [.red, .green, .blue, .alpha],
            colour: .rgb, alpha: channels == 4 ? .straight : .absent,
            planes: [.init(width: 16, height: 9, components: Array(0..<channels), offset: 8,
                sampleStride: step, pixelStride: channels * step, rowBytes: row, byteCount: 8 + row * 9)])
        return try ImageDestination.allocate(descriptor: descriptor).write { bytes in
            for y in 0..<9 { for x in 0..<16 { for c in 0..<channels {
                let i = (y * 16 + x) * channels + c, offset = 8 + y * row + x * channels * step + c * step
                let value = bits == 8 ? (i * 7 + frame * 63) % 256 : (i * 257 + frame * 769) % 65536
                if step == 1 { bytes[offset] = UInt8(value) }
                else { bytes[offset] = UInt8(value >> 8); bytes[offset + 1] = UInt8(truncatingIfNeeded: value) }
            } } }
        }
    }
    @Test(arguments: [false, true], [8, 16])
    func owningSequenceRoundTrip(_ lossy: Bool, _ bits: Int) async throws {
        for channels in [3, 4] {
            let durations: [UInt32] = [10, 300, .max]
            let frames = try (0..<3).map { try AnimationInputFrame(image: source(bits: bits, channels: channels, frame: $0), durationTicks: durations[$0]) }
            let encoder = try Encoder(configuration: .init(mode: lossy ? .lossy : .lossless))
            let audit = ScalarStorageAudit(), progress = Mutex<[ProgressUpdate]>([])
            let encoded = try await ScalarStorageAudit.$current.withValue(audit) {
                try await encoder.encodeAnimation(frames, animation: .init(loopCount: 3),
                    options: .init(copyPolicy: .requireSharedStorage, progress: { update in progress.withLock { $0.append(update) } }))
            }
            #expect(audit.snapshot.finalPixelAllocations == 0 && encoded.encoded.report.copyEvents.isEmpty)
            #expect(encoded.frameCount == 3 && encoded.timing.totalTicks == UInt64(UInt32.max) + 310)
            #expect(encoded.encoded.report.fidelity == (lossy ? .lossy : .exactSamples))
            #expect(progress.withLock { $0.filter { $0.phase == .completed }.count } == 1)
            let decoded = try await Decoder().decodeAll(encoded.encoded.data)
            #expect(decoded.timing == encoded.timing && decoded.frames.map(\.durationTicks) == durations)
            var exported = Data()
            for frame in decoded.frames {
                let d = frame.decoded.image.descriptor, step = d.storageBits / 8
                #expect(d.meaningfulBits == bits && d.alpha == (channels == 4 ? .straight : .absent))
                try frame.decoded.image.storage.withUnsafeBytes { bytes in
                    for i in 0..<(16 * 9 * channels) {
                        let actual = Int(bytes[i * step]) | (step == 2 ? Int(bytes[i * step + 1]) << 8 : 0)
                        exported.append(UInt8(truncatingIfNeeded: actual)); exported.append(UInt8(actual >> 8))
                        if !lossy || (channels == 4 && i % channels == 3) {
                            let expected = bits == 8 ? (i * 7 + frame.index * 63) % 256 : (i * 257 + frame.index * 769) % 65536
                            #expect(actual == expected)
                        }
                    }
                }
            }
            if let directory = ProcessInfo.processInfo.environment["SWIFTJXL_ANIMATION_OUTPUT"] {
                let root = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let stem = "enc-\(lossy ? "lossy" : "lossless")-\(bits)-\(channels)"
                try encoded.encoded.data.write(to: root.appendingPathComponent(stem + ".jxl"))
                try exported.write(to: root.appendingPathComponent(stem + ".decoded"))
            }
        }
    }
    @Test func limitsSingletonAndCancellation() async throws {
        let frame = try AnimationInputFrame(image: source(bits: 8, channels: 3, frame: 0))
        let encoder = try Encoder()
        let still = try await encoder.encode(frame.image)
        let decoder = try Decoder(), stillFrames = try await decoder.decodeAll(still.data)
        #expect(stillFrames.timing == nil && stillFrames.frames.count == 1 && stillFrames.frames[0].durationTicks == 0)
        #expect(try decoder.countFrames(still.data) == 1)
        #expect(try decoder.inspectFrames(still.data).timing == nil)
        #expect(try await decoder.decodeFrame(still.data, at: 0).timing == nil)
        let single = try await encoder.encodeAnimation([frame], animation: .init(ticksPerSecondNumerator: 1000,
            ticksPerSecondDenominator: 1001, loopCount: .max))
        let info = try Decoder().inspectFrames(single.encoded.data)
        #expect(info.timing?.loopCount == UInt32.max && info.timing?.ticksPerSecondDenominator == 1001)
        #expect(info.frames.count == 1 && info.frames[0].durationTicks == 10)
        await #expect(throws: CodecError.self) { _ = try await encoder.encodeAnimation([]) }
        #expect(throws: CodecError.self) { _ = try AnimationInputFrame(image: frame.image, durationTicks: 0) }
        #expect(throws: CodecError.self) { _ = try AnimationEncodingOptions(ticksPerSecondNumerator: 0) }
        #expect(throws: CodecError.self) { _ = try AnimationEncodingOptions(ticksPerSecondDenominator: 1025) }
        let other = try AnimationInputFrame(image: source(bits: 16, channels: 3, frame: 0))
        await #expect(throws: CodecError.self) { _ = try await encoder.encodeAnimation([frame, other]) }
        for limit in [try ResourceLimits(maximumFrames: 1), try ResourceLimits(maximumDecodedBytes: frame.image.storage.byteCount),
                      try ResourceLimits(maximumPixels: 16 * 9), try ResourceLimits(maximumCompressedBytes: 1),
                      try ResourceLimits(maximumMetadataBytes: 43), try ResourceLimits(maximumMemoryBytes: 100000),
                      try ResourceLimits(deadlineSeconds: 1e-100)] {
            do { _ = try await encoder.encodeAnimation([frame, frame], options: .init(resourceLimits: limit)); Issue.record("Ignored sequence limit") }
            catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
        }
        let task = Task {
            try await encoder.encodeAnimation([frame, frame], options: .init(progress: { update in
                if update.phase == .processing && update.completedUnits == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }))
        }
        do { _ = try await task.value; Issue.record("Cancelled animation returned") }
        catch is CancellationError {}
    }
}
