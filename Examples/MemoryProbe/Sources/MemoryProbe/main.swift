// SPDX-License-Identifier: Apache-2.0
// Run without sanitizers. Global heap snapshots are observations, not peak metrics.
import Foundation
import SwiftJXL
#if os(macOS)
import Darwin
#endif

@main struct MemoryProbe {
    static func main() async throws {
        #if os(macOS)
        func heap() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return Int(stats.size_in_use)
        }
        let descriptor = try ImageDescriptor.greyscale16(width: 256, height: 256)
        let image = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { x, y in
            UInt16((x * 7919 + y) & 65535)
        }
        let encoded = try await Encoder().encode(image).data
        // Warm runtime/codec allocation paths before retaining a fresh result.
        for _ in 0..<5 { _ = try await Decoder().decode(encoded) }
        let before = heap()
        let decoded = try await Decoder().decode(encoded)
        let after = heap()
        guard try decoded.image.sampleUInt16(x: 255, y: 255) == image.sampleUInt16(x: 255, y: 255) else {
            throw CodecError(.internalFailure, "Probe sample mismatch")
        }
        let callerDestination = try ImageDestination.allocate(descriptor: descriptor)
        let callerBefore = heap()
        let shared = try await Decoder().decode(encoded, into: callerDestination)
        let callerAfter = heap()
        guard shared.image.storage.allocationID == callerDestination.storage.allocationID,
              try await Encoder().encode(shared.image).data == encoded else {
            throw CodecError(.internalFailure, "Probe identity/codestream mismatch")
        }
        let report: [String: Any] = ["build": "ordinary, no sanitizers", "dimensions": [256, 256],
            "allocatingBeforeBytes": before, "allocatingAfterBytes": after,
            "callerBeforeBytes": callerBefore, "callerAfterBytes": callerAfter,
            "finalPixelBytes": 131072, "note": "Process heap snapshots; not peak workspace or an exact per-operation allocation count"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        #else
        throw CodecError(.unsupportedFeature, "This allocator snapshot probe requires macOS.")
        #endif
    }
}
