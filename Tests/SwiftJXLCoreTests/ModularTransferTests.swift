// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL

struct ModularTransferTests {
    @Test(arguments: [1, 2, 3, 4], [8, 12, 16])
    func independentBT709PreservesSamplesAndRequiredMeaning(_ channels: Int, _ bits: Int) async throws {
        let file = try #require(Bundle.module.url(forResource: "bt709-\(channels)-\(bits)",
            withExtension: "jxl", subdirectory: "Modular/Transfer"))
        let data = try Data(contentsOf: file), decoder = try Decoder()
        let info = try decoder.inspect(data)
        let expected = ImageMetadata(entries: ["jpegXL.transferFunction": Data([1])], requiredKeys: ["jpegXL.transferFunction"])
        #expect(info.metadata == expected && info.descriptor.meaningfulBits == bits)
        let decoded = try await decoder.decode(data)
        #expect(decoded.image.metadata == expected)
        let maximum = (1 << bits) - 1
        try decoded.image.storage.withUnsafeBytes { raw in
            var exact = true
            for i in 0..<(513 * 3) { for c in 0..<channels {
                let p = (i * channels + c) * 2
                if Int(raw[p]) | (Int(raw[p + 1]) << 8) != (i * 71 + (i / 513) * 37 + c * 113) & maximum { exact = false }
            } }
            #expect(exact)
        }
        for policy: MetadataPolicy in [.preserve, .discardAncillary] {
            let encoded = try await Encoder().encode(decoded.image, options: .init(metadataPolicy: policy))
            #expect(try decoder.inspect(encoded.data).metadata == expected)
            let again = try await decoder.decode(encoded.data)
            let bytes = try decoded.image.storage.withUnsafeBytes { Data($0) }
            #expect(try again.image.storage.withUnsafeBytes { Data($0) } == bytes)
        }
    }

    @Test func invalidTransferAndMetadataLimitsReject() async throws {
        let d = try ImageDescriptor.greyscale16(width: 1, height: 1)
        let pixels = try ImageDestination.allocate(descriptor: d).writeUInt16 { _, _ in 65535 }
        for (data, category): (Data, CodecError.Category) in [
            (Data(), .invalidArgument), (Data([1, 1]), .invalidArgument), (Data([8]), .unsupportedFeature), (Data([255]), .unsupportedFeature)
        ] {
            let image = try Image(descriptor: d, storage: pixels.storage,
                metadata: .init(entries: ["jpegXL.transferFunction": data], requiredKeys: ["jpegXL.transferFunction"]))
            do { _ = try await Encoder().encode(image); Issue.record("Invalid transfer accepted") }
            catch let error as CodecError { #expect(error.category == category) }
        }
        let image = try Image(descriptor: d, storage: pixels.storage,
            metadata: .init(entries: ["jpegXL.transferFunction": Data([1])], requiredKeys: ["jpegXL.transferFunction"]))
        let encoded = try await Encoder().encode(image)
        let limits = try ResourceLimits(maximumMetadataBytes: 1)
        do { _ = try Decoder().inspect(encoded.data, options: .init(resourceLimits: limits)); Issue.record("Unbudgeted metadata accepted") }
        catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
    }
}
