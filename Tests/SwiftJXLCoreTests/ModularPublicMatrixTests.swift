// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL
@testable import SwiftJXLCore

/// Exhaustive small-image combinations of the advertised integer precision,
/// colour, alpha association, transfer and intent. Each semantic case checks
/// both layouts/endians; 8-bit cases also check both storage widths.
struct ModularPublicMatrixTests {
    struct Case: Sendable {
        let bits: Int, channels: Int, associated: Bool, transfer: UInt8, intent: UInt8
        var metadata: SwiftJXL.ImageMetadata {
            var entries: [String: Data] = [:]
            if transfer != 13 { entries["jpegXL.transferFunction"] = Data([transfer]) }
            if intent != 1 { entries["jpegXL.renderingIntent"] = Data([intent]) }
            return .init(entries: entries, requiredKeys: Set(entries.keys))
        }
        var fixture: ModularProfileCase { .init(width: 5, height: 3, channels: channels, bits: bits) }
    }
    static let cases: [Case] = {
        var values: [Case] = []
        for bits in 8...16 { for channels in 1...4 {
            for associated in (channels % 2 == 0 ? [false, true] : [false]) {
                for transfer: UInt8 in [1, 13] { for intent: UInt8 in 0...3 {
                    values.append(.init(bits: bits, channels: channels, associated: associated,
                                        transfer: transfer, intent: intent))
                } }
            }
        } }
        return values
    }()

    private func descriptor(_ c: Case, planar: Bool, bigEndian: Bool, storageBits: Int) throws -> ImageDescriptor {
        let bytes = storageBits / 8
        let roles: [ComponentRole] = (c.channels < 3 ? [.grey] : [.red, .green, .blue]) +
            (c.channels % 2 == 0 ? [.alpha] : [])
        var planes: [PlaneDescriptor] = []
        if planar {
            var offset = 5 * bytes
            for channel in (0..<c.channels).reversed() {
                let row = (5 * 2 + 3 + channel) * bytes
                let capacity = offset + row * 3 + 7 * bytes
                planes.append(try .init(width: 5, height: 3, components: [channel], offset: offset,
                    sampleStride: bytes, pixelStride: bytes * 2, rowBytes: row, byteCount: capacity))
                offset = capacity + 11 * bytes
            }
        } else {
            let pixel = (c.channels + 3) * bytes, row = 5 * pixel + 7 * bytes
            planes = [try .init(width: 5, height: 3, components: Array((0..<c.channels).reversed()),
                offset: 5 * bytes, sampleStride: bytes, pixelStride: pixel, rowBytes: row, byteCount: row * 3 + 12 * bytes)]
        }
        return try ImageDescriptor(width: 5, height: 3, storageBits: storageBits, meaningfulBits: c.bits,
            byteOrder: bigEndian ? .bigEndian : .littleEndian, components: roles,
            colour: c.channels < 3 ? .greyscale : .rgb,
            alpha: c.channels % 2 == 0 ? (c.associated ? .premultiplied : .straight) : .absent, planes: planes)
    }

    private func bytes(_ d: ImageDescriptor, pixels: [[UInt16]], sentinel: UInt8) -> [UInt8] {
        var result = [UInt8](repeating: sentinel, count: d.requiredByteCount)
        for plane in d.planes { for (slot, channel) in plane.components.enumerated() {
            for i in 0..<15 {
                let p = plane.offset + i / 5 * plane.rowBytes + i % 5 * plane.pixelStride + slot * plane.sampleStride
                let value = pixels[channel][i]
                if d.storageBits == 8 { result[p] = UInt8(value) }
                else if d.byteOrder == .bigEndian {
                    result[p] = UInt8(value >> 8); result[p + 1] = UInt8(truncatingIfNeeded: value)
                } else {
                    result[p] = UInt8(truncatingIfNeeded: value); result[p + 1] = UInt8(value >> 8)
                }
            }
        } }
        return result
    }

    @Test(arguments: Array(cases.indices))
    func everyDeclaredIntegerInterpretationAndLayout(_ index: Int) async throws {
        let c = Self.cases[index], encoder = try Encoder(), decoder = try Decoder()
        var pixels = c.fixture.pixels()
        if c.associated {
            for channel in 0..<(c.channels - 1) { for i in 0..<15 {
                pixels[channel][i] = min(pixels[channel][i], pixels[c.channels - 1][i])
            } }
        }
        var canonical: Data?
        for storageBits in (c.bits == 8 ? [8, 16] : [16]) {
            for planar in [false, true] { for bigEndian in [false, true] {
                let d = try descriptor(c, planar: planar, bigEndian: bigEndian, storageBits: storageBits)
                let expected = bytes(d, pixels: pixels, sentinel: 0xA5)
                let source = try ImageDestination.allocate(descriptor: d).write { raw in
                    for i in expected.indices { raw[i] = expected[i] }
                }
                let image = try Image(descriptor: d, storage: source.storage, metadata: c.metadata)
                let encodeAudit = ScalarStorageAudit()
                let encoded = try await ScalarStorageAudit.$current.withValue(encodeAudit) {
                    try await encoder.encode(image)
                }
                #expect(encoded.report.copyEvents.isEmpty && encodeAudit.snapshot.finalPixelAllocations == 0)
                if let canonical { #expect(encoded.data == canonical) }
                else { canonical = encoded.data }
                #expect(try source.storage.withUnsafeBytes { Array($0) } == expected)
                let info = try decoder.inspect(encoded.data)
                #expect(info.descriptor.meaningfulBits == c.bits && info.descriptor.alpha == d.alpha)
                #expect(info.metadata == c.metadata)
                // A different padding value must never enter the codestream.
                let otherBytes = bytes(d, pixels: pixels, sentinel: 0x5A)
                let other = try ImageDestination.allocate(descriptor: d).write { raw in
                    for i in otherBytes.indices { raw[i] = otherBytes[i] }
                }
                let otherImage = try Image(descriptor: d, storage: other.storage, metadata: c.metadata)
                #expect(try await encoder.encode(otherImage, options: .init(metadataPolicy: .discardAncillary)).data == encoded.data)
                let targetDescriptor = try descriptor(c, planar: !planar, bigEndian: !bigEndian, storageBits: storageBits)
                let target = try ImageDestination.allocate(descriptor: targetDescriptor)
                let identity = target.storage.allocationID
                let audit = ScalarStorageAudit()
                let decoded = try await ScalarStorageAudit.$current.withValue(audit) {
                    try await decoder.decode(encoded.data, into: target)
                }
                #expect(decoded.image.storage.allocationID == identity && decoded.image.metadata == c.metadata)
                #expect(decoded.report.copyEvents.isEmpty && audit.snapshot.finalPixelAllocations == 0)
                // Safe allocated destinations start zeroed; full-byte comparison
                // checks sample writes and preservation of their zero padding.
                #expect(try decoded.image.storage.withUnsafeBytes { Array($0) } == bytes(targetDescriptor, pixels: pixels, sentinel: 0))
            } }
        }
        #if os(macOS) || os(Linux)
        if let oracle = ProcessInfo.processInfo.environment["SWIFTJXL_PROFILE_ORACLE"] {
            try independent(try #require(canonical), pixels: pixels, c: c, index: index, oracle: oracle)
        }
        #endif
    }

    #if os(macOS) || os(Linux)
    private func independent(_ data: Data, pixels: [[UInt16]], c: Case, index: Int, oracle: String) throws {
        let saved = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_OUTPUT"]
        let root = saved.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("public-matrix-\(index)-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { if saved == nil { try? FileManager.default.removeItem(at: dir) } }
        try data.write(to: dir.appendingPathComponent("native.jxl"))
        var expected = Data()
        for i in 0..<15 { for channel in 0..<c.channels {
            expected.append(UInt8(truncatingIfNeeded: pixels[channel][i]))
            expected.append(UInt8(pixels[channel][i] >> 8))
        } }
        try expected.write(to: dir.appendingPathComponent("expected.u16le"))
        let log = dir.appendingPathComponent("oracle.json")
        try Data().write(to: log)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: oracle)
        process.arguments = [dir.appendingPathComponent("native.jxl").path,
            dir.appendingPathComponent("expected.u16le").path]
        process.standardOutput = handle; process.standardError = handle
        try process.run(); process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let result = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: log)) as? [String: Int])
        #expect(result["bits"] == c.bits && result["channels"] == c.channels)
        #expect(result["width"] == 5 && result["height"] == 3)
        #expect(result["premultiplied"] == (c.associated ? 1 : 0))
        #expect(result["renderingIntent"] == Int(c.intent) && result["transferFunction"] == Int(c.transfer))
    }
    #endif
}
