// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct ModularICCTests {
    private func fixture(_ channels: Int, _ bits: Int) throws -> (Data, Data) {
        let stream = try #require(Bundle.module.url(forResource: "icc-\(channels)-\(bits)", withExtension: "jxl", subdirectory: "Modular/ICC"))
        let profile = try #require(Bundle.module.url(forResource: channels < 3 ? "gray-gamma22" : "srgb", withExtension: "icc", subdirectory: "JPEGBridge"))
        return (try Data(contentsOf: stream), try Data(contentsOf: profile))
    }

    @Test(arguments: [1, 2, 3, 4], [8, 12, 16])
    func independentSamplesAndProfileArePreserved(_ channels: Int, _ bits: Int) async throws {
        let (data, profile) = try fixture(channels, bits)
        let decoder = try Decoder(), info = try decoder.inspect(data)
        #expect(info.descriptor.iccProfile == profile)
        #expect(info.metadata.entries["jpegXL.transferFunction"] == nil)
        let decoded = try await decoder.decode(data)
        #expect(decoded.image.descriptor.iccProfile == profile)
        let destination = try ImageDestination.allocate(descriptor: info.descriptor)
        let caller = try await decoder.decode(data, into: destination)
        #expect(caller.image.storage.allocationID == destination.storage.allocationID)
        let expectedMaximum = (1 << bits) - 1
        for result in [decoded, caller] {
            let exact = try result.image.storage.withUnsafeBytes { raw in
                for i in 0..<(513 * 3) { for c in 0..<channels {
                    let offset = (i * channels + c) * 2
                    let value = Int(raw[offset]) | (Int(raw[offset + 1]) << 8)
                    if value != (i * 71 + (i / 513) * 37 + c * 113) & expectedMaximum { return false }
                } }
                return true
            }
            #expect(exact)
        }
        do { _ = try await Encoder().encode(decoded.image); Issue.record("ICC encoding was silently accepted") }
        catch let error as CodecError { #expect(error.category == .unsupportedFeature) }
    }

    @Test func profileLimitsAndDestinationMeaningReject() async throws {
        let (data, profile) = try fixture(1, 16), decoder = try Decoder()
        for limits in [try ResourceLimits(maximumMetadataBytes: profile.count - 1),
                       try ResourceLimits(maximumICCBytes: profile.count - 1)] {
            do { _ = try decoder.inspect(data, options: .init(resourceLimits: limits)); Issue.record("ICC size limit ignored") }
            catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
        }
        let exact = try ResourceLimits(maximumMetadataBytes: profile.count, maximumICCBytes: profile.count)
        #expect(try decoder.inspect(data, options: .init(resourceLimits: exact)).descriptor.iccProfile == profile)
        let wrong = try ImageDestination.allocate(descriptor: .greyscale16(width: 513, height: 3))
        do { _ = try await decoder.decode(data, into: wrong); Issue.record("ICC interpretation was discarded") }
        catch let error as CodecError { #expect(error.category == .incompatibleImageLayout) }
    }

    @Test func malformedProfileAndTruncatedStreamReject() throws {
        let (container, originalProfile) = try fixture(1, 16)
        let data: Data
        switch try parseJXLContainer(container) {
        case .naked: data = container
        case .iso(let boxes): data = try extractCodestream(from: boxes, in: container)
        }
        var reader = BitReader(data, startingAt: 16)
        _ = try SizeHeader.read(from: &reader)
        _ = try SwiftJXLCore.ImageMetadata.read(from: &reader)
        #expect(try reader.readBit())
        let iccStart = reader.position
        _ = try ICCStream.decode(from: &reader, maximumBytes: 65536, checkpoint: {})
        try reader.expectZeroPadding()
        let frameStart = reader.position / 8
        // Preserve valid frame bytes while replacing only its profile payload.
        for offset in [0, 16, 36] {
            var profile = originalProfile
            profile[offset] ^= 1
            var writer = BitWriter(), prefix = BitReader(data)
            for _ in 0..<iccStart { writer.writeBit(try prefix.readBit()) }
            try ICCStream.write(profile, to: &writer, maximumBytes: 65536, checkpoint: {})
            writer.alignToByte()
            writer.appendBytes(Data(data.dropFirst(frameStart)))
            do { _ = try Decoder().inspect(writer.finishToData()); Issue.record("Malformed profile accepted") }
            catch let error as CodecError { #expect(error.category == .malformedInput) }
        }
        for count in [iccStart / 8, frameStart - 1, data.count - 1] {
            #expect(throws: CodecError.self) { try Decoder().inspect(Data(data.prefix(count))) }
        }
    }
}
