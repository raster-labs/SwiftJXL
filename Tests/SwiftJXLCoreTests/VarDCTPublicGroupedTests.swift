// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct VarDCTPublicGroupedTests {
    @Test(arguments: ["grouped-257-17-4-8", "grouped-17-257-2-16", "grouped-257-259-4-8",
                      "grouped-2057-9-3-8", "grouped-9-2057-1-16", "grouped-2057-9-4-16"])
    func publicGroupedStorageAndReference(_ name: String) async throws {
        let parts = name.split(separator: "-").dropFirst().compactMap { Int($0) }
        let width = parts[0], height = parts[1], channels = parts[2], bits = parts[3]
        func fixture(_ suffix: String) throws -> Data {
            try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: suffix,
                subdirectory: "VarDCT/GroupedDecoder")))
        }
        let source = try fixture("jxl"), reference = try fixture("scalar-oracle")
        let decoder = try Decoder(), info = try decoder.inspect(source)
        #expect(info.descriptor.width == width && info.descriptor.height == height)
        #expect(info.descriptor.meaningfulBits == bits)
        let row = width * 2 + 8, planeSize = row * height + 12
        let planes = try (0..<channels).map { c in
            try PlaneDescriptor(width: width, height: height, components: [c], offset: 16 + c * planeSize,
                sampleStride: 2, pixelStride: 2, rowBytes: row, byteCount: 16 + (c + 1) * planeSize)
        }
        let descriptor = try ImageDescriptor(width: width, height: height, storageBits: 16,
            meaningfulBits: bits, byteOrder: .bigEndian, components: info.descriptor.components,
            colour: info.descriptor.colour, alpha: info.descriptor.alpha, planes: planes)
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        let identity = destination.storage.allocationID, audit = ScalarStorageAudit()
        let decoded = try await ScalarStorageAudit.$current.withValue(audit) {
            try await decoder.decode(source, into: destination)
        }
        #expect(decoded.image.storage.allocationID == identity)
        #expect(decoded.report.copyEvents.isEmpty && decoded.report.fidelity == .lossy)
        #expect(audit.snapshot.finalPixelAllocations == 0)
        var peak = 0, squared = 0.0, colourCount = 0
        try decoded.image.storage.withUnsafeBytes { bytes in
            for y in 0..<height { for x in 0..<width { for c in 0..<channels {
                let offset = 16 + c * planeSize + y * row + x * 2
                let actual = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                let raw = reference.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: ((y * width + x) * channels + c) * 4, as: UInt32.self) }
                let expected = Int((Double(min(1, max(0, Float(bitPattern: UInt32(littleEndian: raw))))) * Double((1 << bits) - 1)).rounded())
                if channels % 2 == 0 && c == channels - 1 { #expect(actual == expected) }
                else { let error = abs(actual - expected); peak = max(peak, error); squared += Double(error * error); colourCount += 1 }
            } } }
        }
        #expect(peak <= 2 && sqrt(squared / Double(colourCount)) <= 0.5)
    }
}
