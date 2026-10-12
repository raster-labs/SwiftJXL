// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct AnimationPublicTests {
    private func fixture(_ name: String, suffix: String = "jxl") throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: suffix, subdirectory: "VarDCT/Animation")))
    }
    @Test(arguments: ["libjxl-lossless", "libjxl-lossy-epf0", "libjxl-lossless-rgba16", "libjxl-lossy-rgba16-epf0"])
    func publicFramesMatchAllFrameScalarOracle(_ name: String) async throws {
        let data = try fixture(name), oracle = try fixture(name, suffix: "float")
        let decoder = try Decoder()
        let bits = name.contains("rgba16") ? 16 : 8, channels = name.contains("rgba16") ? 4 : 3
        let sampleMaximum = (1 << bits) - 1, lossless = name.contains("lossless")
        #expect(try decoder.countFrames(data) == 3)
        let info = try decoder.inspectFrames(data)
        #expect(info.frames.map(\.durationTicks) == [10, 20, 30])
        #expect(info.timing?.loopCount == 3 && info.timing?.totalTicks == 60)
        #expect(info.timing?.ticksPerSecondNumerator == 100 && info.timing?.ticksPerSecondDenominator == 1)
        let progress = Mutex<[ProgressUpdate]>([])
        let audit = ScalarStorageAudit()
        let result = try await ScalarStorageAudit.$current.withValue(audit) {
            try await decoder.decodeAll(data, options: .init(copyPolicy: .requireSharedStorage,
                progress: { value in progress.withLock { $0.append(value) } }))
        }
        #expect(audit.snapshot.finalPixelAllocations == 3)
        #expect(result.frames.count == 3 && result.timing == info.timing)
        #expect(result.compressedFrameBytesMaterialised == info.compressedFrameBytesMaterialised)
        #expect(progress.withLock { $0.filter { $0.phase == .completed }.count } == 1)
        #expect(progress.withLock { $0.last?.completedUnits } == 3)
        for frame in result.frames {
            #expect(frame.decoded.report.fidelity == (lossless ? .exactSamples : .lossy))
            #expect(frame.decoded.report.copyEvents.isEmpty)
            #expect(frame.decoded.image.descriptor.meaningfulBits == bits)
            let indexed = try await decoder.decodeFrame(data, at: frame.index)
            let bytes = try frame.decoded.image.storage.withUnsafeBytes { Data($0) }
            #expect(try indexed.decoded.image.storage.withUnsafeBytes { Data($0) } == bytes)
            var peak = 0, squares = 0.0, colourSamples = 0
            let step = frame.decoded.image.descriptor.storageBits / 8
            for i in 0..<(16 * 9 * channels) {
                let actual = Int(bytes[i * step]) | (step == 2 ? Int(bytes[i * step + 1]) << 8 : 0)
                let raw = oracle.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: (frame.index * 16 * 9 * channels + i) * 4, as: UInt32.self) }
                let reference = Int((Double(min(1, max(0, Float(bitPattern: UInt32(littleEndian: raw))))) * Double(sampleMaximum)).rounded())
                let delta = abs(actual - reference)
                let alpha = channels == 4 && i % channels == 3
                if alpha { #expect(delta == 0) }
                else { peak = max(peak, delta); squares += Double(delta * delta); colourSamples += 1 }
                if lossless || alpha {
                    let original = bits == 8 ? (i * 7 + frame.index * 63) % 256 : (i * 257 + frame.index * 769) % 65536
                    #expect(actual == original)
                }
            }
            #expect(peak <= 2 && sqrt(squares / Double(colourSamples)) <= 0.5)
        }
        await #expect(throws: CodecError.self) { _ = try await decoder.decode(data) }
    }
    @Test func aggregateLimitsAndCancellation() async throws {
        let data = try fixture("libjxl-lossless"), decoder = try Decoder()
        do { _ = try await decoder.decodeAll(fixture("libjxl-lossy")); Issue.record("Unsupported filter rewrite accepted") }
        catch let error as CodecError { #expect(error.category == .unsupportedFeature) }
        for options in [try DecodeOptions(resourceLimits: .init(maximumFrames: 2)),
                        try DecodeOptions(resourceLimits: .init(maximumDecodedBytes: 16 * 9 * 3 * 2)),
                        try DecodeOptions(resourceLimits: .init(maximumPixels: 16 * 9 * 2)),
                        try DecodeOptions(resourceLimits: .init(maximumMetadataBytes: 30)),
                        try DecodeOptions(resourceLimits: .init(maximumMemoryBytes: 200000)),
                        try DecodeOptions(resourceLimits: .init(deadlineSeconds: 1e-100))] {
            do { _ = try await decoder.decodeAll(data, options: options); Issue.record("Ignored sequence limit") }
            catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
        }
        let exactMetadata = try await decoder.decodeAll(data, options: .init(resourceLimits: .init(maximumMetadataBytes: 56)))
        #expect(exactMetadata.frames.count == 3)
        _ = try await decoder.decodeFrame(data, at: 2, options: .init(resourceLimits: .init(maximumPixels: 16 * 9)))
        for i in [-1, 3] {
            do { _ = try await decoder.decodeFrame(data, at: i); Issue.record("Accepted invalid index") }
            catch let error as CodecError { #expect(error.category == .invalidArgument) }
        }
        let task = Task {
            try await decoder.decodeAll(data, options: .init(progress: { value in
                if value.phase == .processing && value.completedUnits == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }))
        }
        do { _ = try await task.value; Issue.record("Cancelled sequence returned") }
        catch is CancellationError {}
    }
}
