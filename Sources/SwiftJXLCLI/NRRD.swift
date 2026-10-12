// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXL

/// CLI-only attached/raw UInt16 profile; specification pin: NRRD_PROFILE.md.
struct NRRD {
    static let maximumHeader = 16 * 1024
    let width: Int
    let height: Int
    let order: ByteOrder
    let payloadOffset: Int

    static func parse(_ data: Data, io: CommandIO) throws -> Self {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var cursor = 0
            var lines = 0
            func line() throws -> String {
                try io.checkpoint()
                lines += 1
                guard lines <= 64 else { throw CodecError(.resourceLimitExceeded, "NRRD header has too many lines.") }
                let start = cursor
                while cursor < bytes.count, bytes[cursor] != 10 {
                    guard cursor < maximumHeader, cursor - start < 1024 else {
                        throw CodecError(.resourceLimitExceeded, "NRRD header limit exceeded.")
                    }
                    cursor += 1
                }
                guard cursor < bytes.count else { throw CodecError(.malformedInput, "Truncated NRRD header.") }
                var end = cursor
                cursor += 1
                guard cursor <= maximumHeader else { throw CodecError(.resourceLimitExceeded, "NRRD header limit exceeded.") }
                if end > start, bytes[end - 1] == 13 { end -= 1 }
                let raw = UnsafeRawBufferPointer(rebasing: bytes[start..<end])
                guard raw.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else {
                    throw CodecError(.malformedInput, "NRRD header must contain ASCII text.")
                }
                return String(decoding: raw, as: UTF8.self)
            }
            let magic = try line()
            guard magic == "NRRD0005" else {
                throw CodecError(magic.hasPrefix("NRRD") ? .unsupportedFormat : .malformedInput,
                                 "Expected the attached NRRD0005 profile.")
            }
            var fields: [String: String] = [:]
            while true {
                let text = try line()
                if text.isEmpty { break }
                if text.hasPrefix("#") { continue }
                guard !text.contains(":=") else { throw CodecError(.unsupportedFeature, "NRRD custom metadata is not representable.") }
                guard let separator = text.range(of: ": "), text.first != " ", text.first != "\t" else {
                    throw CodecError(.malformedInput, "Malformed NRRD field.")
                }
                let key = String(text[..<separator.lowerBound]).lowercased()
                let value = String(text[separator.upperBound...]).trimmingCharacters(in: .whitespaces).lowercased()
                guard ["type", "dimension", "sizes", "endian", "encoding", "kinds"].contains(key) else {
                    throw CodecError(.unsupportedFeature, "NRRD field is outside the bounded profile.")
                }
                guard fields[key] == nil else { throw CodecError(.malformedInput, "Duplicate NRRD field.") }
                if key == "sizes" || key == "kinds" {
                    guard fields["dimension"] != nil else { throw CodecError(.malformedInput, "NRRD dimension must precede per-axis fields.") }
                }
                fields[key] = value
            }
            guard let type = fields["type"], let dimension = fields["dimension"],
                  let sizes = fields["sizes"], let endian = fields["endian"], let encoding = fields["encoding"] else {
                throw CodecError(.malformedInput, "NRRD is missing a required field.")
            }
            guard ["ushort", "unsigned short", "unsigned short int", "uint16", "uint16_t"].contains(type),
                  dimension == "2", encoding == "raw", ["little", "big"].contains(endian),
                  fields["kinds"] == nil || fields["kinds"]?.split(whereSeparator: { $0 == " " || $0 == "\t" }) == ["domain", "domain"] else {
                throw CodecError(.unsupportedFeature, "Only 2D raw full-precision UInt16 NRRD is supported.")
            }
            let counts = sizes.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard counts.count == 2, counts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else {
                throw CodecError(.malformedInput, "Invalid NRRD sizes.")
            }
            guard let width = Int(counts[0]), let height = Int(counts[1]), width <= 1024, height <= 1024 else {
                throw CodecError(.resourceLimitExceeded, "NRRD dimensions exceed admission limits.")
            }
            guard width > 0, height > 0 else { throw CodecError(.malformedInput, "NRRD dimensions must be positive.") }
            // The dimension ceiling proves multiplication and addition fit in Int.
            guard bytes.count - cursor == width * height * 2 else {
                throw CodecError(.malformedInput, "NRRD payload length does not match its dimensions.")
            }
            return Self(width: width, height: height, order: endian == "little" ? .littleEndian : .bigEndian, payloadOffset: cursor)
        }
    }

    func image(_ data: Data, limits: ResourceLimits) throws -> Image {
        let bytes = width * height * 2
        let plane = try PlaneDescriptor(width: width, height: height, rowBytes: width * 2, byteCount: bytes)
        let descriptor = try ImageDescriptor(width: width, height: height, byteOrder: order, planes: [plane], limits: limits)
        return try Image(descriptor: descriptor, storage: InterchangePayloadOwner(data: data, offset: payloadOffset), limits: limits)
    }

    static func requireRepresentable(_ descriptor: ImageDescriptor, metadata: ImageMetadata) throws {
        guard descriptor.meaningfulBits == 16, descriptor.storageBits == 16,
              descriptor.colour == .greyscale, descriptor.components == [.grey],
              descriptor.iccProfile == nil, metadata.entries.isEmpty else {
            throw CodecError(.unsupportedFeature, "NRRD output cannot preserve this precision or interpretation metadata.")
        }
    }

    static func write(_ image: Image, fd: Int32, io: CommandIO) throws {
        let d = image.descriptor
        try requireRepresentable(d, metadata: image.metadata)
        guard d.planes.count == 1, let p = d.planes.first, p.pixelStride == 2 else {
            throw CodecError(.incompatibleImageLayout, "NRRD output requires a contiguous greyscale row.")
        }
        let header = "NRRD0005\ntype: uint16\ndimension: 2\nsizes: \(d.width) \(d.height)\nencoding: raw\nendian: \(d.byteOrder == .bigEndian ? "big" : "little")\n\n"
        try io.writeBytes(Data(header.utf8), fd: fd)
        // Borrow the owning decoded image directly. No full-image serialisation
        // array, byte-order conversion, async pointer or intermediate file.
        try image.storage.withUnsafeBytes { bytes in
            for y in 0..<d.height {
                let start = p.offset + y * p.rowBytes
                try io.writeRaw(UnsafeRawBufferPointer(rebasing: bytes[start..<(start + d.width * 2)]), fd: fd)
            }
        }
    }
}

/// Owns immutable input Data across encoder suspension. The rebase happens only
/// inside each synchronous borrow; no borrowed pointer is retained or returned.
final class InterchangePayloadOwner: ReadOnlyImageStorage, Sendable {
    private let data: Data
    private let offset: Int
    let allocationID = UUID()
    var byteCount: Int { data.count - offset }
    init(data: Data, offset: Int) { self.data = data; self.offset = offset }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        try data.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[offset...])) }
    }
}
