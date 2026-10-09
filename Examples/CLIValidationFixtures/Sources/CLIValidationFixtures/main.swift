// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXL

@main struct CLIValidationFixtures {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw CodecError(.invalidArgument, "Supply a new fixture output directory.")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw CodecError(.invalidArgument, "Fixture directory must be new.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for bits in [12, 16] {
            let descriptor = try ImageDescriptor.greyscale16(width: 7, height: 5, meaningfulBits: bits)
            let image = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { x, y in
                UInt16(((y * 7 + x) * 7919) & ((1 << bits) - 1))
            }
            let encoded = try await Encoder().encode(image).data
            try encoded.write(to: root.appendingPathComponent("scalar-\(bits).jxl"))
            if bits == 12 {
                // Find a payload-only corruption, keeping supported headers
                // inspectable. Store its exact offset/mask for reproducibility.
                var found = false
                for offset in encoded.indices.reversed() {
                    if found { break }
                    for bit in 0..<8 {
                        var damaged = encoded
                        damaged[offset] ^= UInt8(1 << bit)
                        guard (try? Decoder().inspect(damaged)) != nil else { continue }
                        do { _ = try await Decoder().decode(damaged) }
                        catch let error as CodecError where error.category == .malformedInput {
                            try damaged.write(to: root.appendingPathComponent("damaged-payload.jxl"))
                            try Data("{\"offset\":\(offset),\"mask\":\(1 << bit)}\n".utf8)
                                .write(to: root.appendingPathComponent("mutation.json"))
                            found = true
                            break
                        }
                    }
                }
                guard found else { throw CodecError(.internalFailure, "No deterministic payload mutation found.") }
            }
        }
    }
}
