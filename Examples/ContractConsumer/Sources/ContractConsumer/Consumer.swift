// SPDX-License-Identifier: MIT
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
        let image = try destination.writeUInt16 { x, y in
            UInt16((y * 3 + x) * 819)
        }
        let encoder = try SwiftJXL.Encoder(configuration: .init())
        let encoded = try await encoder.encode(image)
        let decoder = try SwiftJXL.Decoder(configuration: .init())
        let decoded = try await decoder.decode(encoded.data)
        try checkSamples(decoded.image)
        // A different padded row stride exercises the public shared-storage path.
        let outputDescriptor = try SwiftJXL.ImageDescriptor.greyscale16(
            width: 3, height: 2, meaningfulBits: 12, rowBytes: 10)
        let output = try SwiftJXL.ImageDestination.allocate(descriptor: outputDescriptor)
        let identity = output.storage.allocationID
        let shared = try await decoder.decode(encoded.data, into: output)
        try checkSamples(shared.image)
        guard shared.image.storage.allocationID == identity,
              shared.report.fidelity == .exactSamples,
              shared.report.copyEvents.isEmpty,
              encoded.report.copyEvents.isEmpty else {
            throw ConsumerFailure.unexpectedResult
        }
        // Optional allocation/peak counters are currently unknown. An absent
        // measurement is not zero; allocation-site proof lives in the codec tests.
        do {
            _ = try output.writeUInt16 { _, _ in 0 }
            throw ConsumerFailure.unexpectedResult
        } catch let error as SwiftJXL.CodecError {
            guard error.category == .storageUnavailable else { throw error }
        }
        let sequence = try await encoder.encodeAnimation([
            try .init(image: image, durationTicks: 10),
            try .init(image: image, durationTicks: 25)
        ], animation: .init(ticksPerSecondNumerator: 100, loopCount: 3))
        let frames = try await decoder.decodeAll(sequence.encoded.data)
        guard frames.frames.count == 2, frames.timing?.totalTicks == 35,
              frames.timing?.loopCount == 3,
              frames.frames[0].decoded.image.storage.allocationID != frames.frames[1].decoded.image.storage.allocationID else {
            throw ConsumerFailure.unexpectedResult
        }
        for frame in frames.frames { try checkSamples(frame.decoded.image) }
        let transcoder = try SwiftJXL.Transcoder(configuration: .init())
        do {
            _ = try await transcoder.transcode(Data(), to: .jpegXL, options: .init())
            throw ConsumerFailure.unexpectedResult
        } catch let error as SwiftJXL.CodecError {
            guard error.category == .malformedInput else { throw error }
        }
        print("Public consumer passed: exact UInt16 samples, shared destination, sealed ownership and animation timing.")
    }

    static func checkSamples(_ image: SwiftJXL.Image) throws {
        guard image.descriptor.width == 3, image.descriptor.height == 2,
              image.descriptor.meaningfulBits == 12 else {
            throw ConsumerFailure.unexpectedResult
        }
        for y in 0..<2 {
            for x in 0..<3 {
                guard try image.sampleUInt16(x: x, y: y) == UInt16((y * 3 + x) * 819) else {
                    throw ConsumerFailure.unexpectedResult
                }
            }
        }
    }
}
