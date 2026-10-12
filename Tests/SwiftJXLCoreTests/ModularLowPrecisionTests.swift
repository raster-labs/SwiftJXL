// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL

struct ModularLowPrecisionTests {
    @Test(arguments: [1, 2, 3, 4], Array(1...7))
    func independentSmallPrecisionSamples(_ channels: Int, _ bits: Int) async throws {
        let url = try #require(Bundle.module.url(forResource: "low-\(channels)-\(bits)", withExtension: "jxl", subdirectory: "Modular/LowPrecision"))
        let data = try Data(contentsOf: url), decoder = try Decoder()
        let info = try decoder.inspect(data)
        #expect(info.descriptor.meaningfulBits == bits)
        let allocated = try await decoder.decode(data)
        #expect(allocated.image.descriptor.storageBits == 16)
        let roles = info.descriptor.components
        let plane = try PlaneDescriptor(width: 513, height: 3, components: Array(roles.indices),
            sampleStride: 1, pixelStride: channels, rowBytes: 513 * channels, byteCount: 513 * 3 * channels)
        let descriptor = try ImageDescriptor(width: 513, height: 3, storageBits: 8, meaningfulBits: bits,
            components: roles, colour: info.descriptor.colour, alpha: info.descriptor.alpha, planes: [plane])
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        let caller = try await decoder.decode(data, into: destination)
        #expect(caller.image.storage.allocationID == destination.storage.allocationID)
        for result in [allocated, caller] {
            let sampleBytes = result.image.descriptor.storageBits / 8
            let exact = try result.image.storage.withUnsafeBytes { raw in
                for i in 0..<(513 * 3) { for c in 0..<channels {
                    let offset = (i * channels + c) * sampleBytes
                    let expected = (i * 71 + (i / 513) * 37 + c * 113) & ((1 << bits) - 1)
                    if Int(raw[offset]) != expected || (sampleBytes == 2 && raw[offset + 1] != 0) { return false }
                } }
                return true
            }
            #expect(exact)
        }
        // The predecessor's encoder did not expose these meaningful precisions.
        do { _ = try await Encoder().encode(caller.image); Issue.record("Precision was silently widened on encode") }
        catch let error as CodecError { #expect(error.category == .unsupportedFeature) }
    }

    @Test func directionSpecificCapabilities() {
        #expect(Decoder.capabilities.meaningfulPrecision == 1...16)
        #expect(Encoder.capabilities.meaningfulPrecision == 8...16)
    }
}
