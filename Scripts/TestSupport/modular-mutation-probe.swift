// SPDX-License-Identifier: Apache-2.0
// Test-only public-entry probe. Link the current ASan-instrumented module objects.
import Foundation
import SwiftJXL

@main struct ModularMutationProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3, ["inspect", "decode", "caller"].contains(args[1]) else {
            throw NSError(domain: "probe arguments", code: 1)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let limits = try ResourceLimits(maximumCompressedBytes: 1 << 20,
            maximumDecodedBytes: 8 << 20, maximumWorkspaceBytes: 120 << 20,
            maximumPixels: 262144, maximumDimension: 8192, maximumFrames: 1,
            maximumMetadataBytes: 65536, maximumICCBytes: 65536,
            maximumNestingDepth: 16, maximumWorkers: 1, deadlineSeconds: 5,
            maximumMemoryBytes: 128 << 20)
        let options = DecodeOptions(resourceLimits: limits, executionPolicy: .scalarCPU)
        let decoder = try Decoder()
        do {
            if args[1] == "inspect" {
                _ = try decoder.inspect(data, options: options)
            } else {
                let result: DecodedImage
                if args[1] == "caller" {
                    let info = try decoder.inspect(data, options: options)
                    let destination = try ImageDestination.allocate(descriptor: info.descriptor, limits: limits)
                    result = try await decoder.decode(data, into: destination, options: options)
                    guard result.image.storage.allocationID == destination.storage.allocationID else {
                        throw NSError(domain: "caller allocation replaced", code: 2)
                    }
                } else {
                    result = try await decoder.decode(data, options: options)
                }
                let d = result.image.descriptor
                guard d.storageBits == 16, (8...16).contains(d.meaningfulBits),
                      result.image.storage.byteCount == d.requiredByteCount else {
                    throw NSError(domain: "decoded layout invariant", code: 3)
                }
                let maximum = (1 << d.meaningfulBits) - 1
                let valid = try result.image.storage.withUnsafeBytes { bytes in
                    for p in stride(from: 0, to: bytes.count, by: 2) {
                        if (Int(bytes[p]) | Int(bytes[p + 1]) << 8) > maximum { return false }
                    }
                    return true
                }
                guard valid else { throw NSError(domain: "decoded sample invariant", code: 4) }
            }
            print("accepted")
        } catch let error as CodecError {
            print("rejected:\(error.category.rawValue)")
        }
    }
}
