// SPDX-License-Identifier: Apache-2.0
// Test-only owning animation API probe; link ASan-instrumented module objects.
import Foundation
import SwiftJXL

@main struct AnimationMutationProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw NSError(domain: "probe arguments", code: 1) }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let limits = try ResourceLimits(maximumCompressedBytes: 1 << 20,
            maximumDecodedBytes: 8 << 20, maximumWorkspaceBytes: 120 << 20,
            maximumPixels: 262144, maximumDimension: 8192, maximumFrames: 16,
            maximumMetadataBytes: 65536, maximumICCBytes: 65536,
            maximumNestingDepth: 16, maximumWorkers: 1, deadlineSeconds: 5,
            maximumMemoryBytes: 128 << 20)
        let options = DecodeOptions(resourceLimits: limits, executionPolicy: .scalarCPU)
        let decoder = try Decoder()
        do {
            switch args[1] {
            case "animation-count":
                guard try decoder.countFrames(data, options: options) > 0 else {
                    throw NSError(domain: "empty frame count", code: 2)
                }
            case "animation-inspect":
                let result = try decoder.inspectFrames(data, options: options)
                guard !result.frames.isEmpty else { throw NSError(domain: "empty frame inspection", code: 3) }
            case "animation-frame":
                let count = try decoder.countFrames(data, options: options)
                let result = try await decoder.decodeFrame(data, at: count - 1, options: options)
                try validate(result.decoded)
                guard result.index == count - 1 else { throw NSError(domain: "wrong frame index", code: 4) }
            case "animation-all":
                let result = try await decoder.decodeAll(data, options: options)
                guard !result.frames.isEmpty else { throw NSError(domain: "empty decoded sequence", code: 5) }
                var owners = Set<UUID>()
                for (index, frame) in result.frames.enumerated() {
                    try validate(frame.decoded)
                    guard frame.index == index, owners.insert(frame.decoded.image.storage.allocationID).inserted else {
                        throw NSError(domain: "frame owner/index invariant", code: 6)
                    }
                }
            default: throw NSError(domain: "unknown probe entry", code: 7)
            }
            print("accepted")
        } catch let error as CodecError {
            print("rejected:\(error.category.rawValue)")
        }
    }
    static func validate(_ decoded: DecodedImage) throws {
        let d = decoded.image.descriptor
        guard d.storageBits == 16, (1...16).contains(d.meaningfulBits),
              decoded.image.storage.byteCount == d.requiredByteCount else {
            throw NSError(domain: "decoded layout invariant", code: 8)
        }
        let maximum = (1 << d.meaningfulBits) - 1
        let valid = try decoded.image.storage.withUnsafeBytes { bytes in
            for p in stride(from: 0, to: bytes.count, by: 2) {
                if (Int(bytes[p]) | Int(bytes[p + 1]) << 8) > maximum { return false }
            }
            return true
        }
        guard valid else { throw NSError(domain: "decoded sample invariant", code: 9) }
    }
}
