// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXL

enum ConsumerFailure: Error { case unexpectedResult }

@main
struct ContractConsumer {
    static func main() async throws {
        // Plain import, public members only; no testable import or sibling package.
        let descriptor = try SwiftJXL.ImageDescriptor.greyscale16(
            width: 3, height: 2, meaningfulBits: 12, rowBytes: 8)
        let destination = try SwiftJXL.ImageDestination.allocate(descriptor: descriptor)
        let image = try destination.write { bytes in
            for y in 0..<2 {
                for x in 0..<3 {
                    let value = UInt16((y * 3 + x) * 819)
                    bytes[y * 8 + x * 2] = UInt8(truncatingIfNeeded: value)
                    bytes[y * 8 + x * 2 + 1] = UInt8(value >> 8)
                }
            }
        }
        let last = try image.storage.withUnsafeBytes { bytes in
            UInt16(bytes[12]) | UInt16(bytes[13]) << 8
        }
        guard last == 4095, image.descriptor.meaningfulBits == 12 else {
            throw ConsumerFailure.unexpectedResult
        }
        let encoder = try SwiftJXL.Encoder(configuration: .init())
        let encoded = try await encoder.encode(image)
        let decoder = try SwiftJXL.Decoder(configuration: .init())
        let decoded = try await decoder.decode(encoded.data)
        guard try decoded.image.sampleUInt16(x: 2, y: 1) == 4095,
              decoded.image.descriptor.meaningfulBits == 12 else {
            throw ConsumerFailure.unexpectedResult
        }
        let transcoder = try SwiftJXL.Transcoder(configuration: .init())
        do {
            _ = try await transcoder.transcode(Data(), to: .jpegXL, options: .init())
            throw ConsumerFailure.unexpectedResult
        } catch let error as SwiftJXL.CodecError {
            guard error.category == .unsupportedFeature else { throw error }
        }
        print("Public consumer passed: owning UInt16 samples and lossless scalar JPEG XL.")
    }
}
