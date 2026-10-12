// SPDX-License-Identifier: Apache-2.0
// New bounded adapter replacing JXLSwift 57e81cb Sources/JXLTool/PNM.swift.
// Format definitions: https://netpbm.sourceforge.net/doc/{ppm,pgm,pam}.html
import Foundation
import SwiftJXL

/// One binary P5/P6/P7 image. Standard interpretation is BT.709; the caller
/// must explicitly select pnm-srgb for that commonly used Netpbm variant.
struct PNM {
    let width: Int, height: Int, channels: Int, bits: Int, payloadOffset: Int
    static let transferKey = "jpegXL.transferFunction"

    static func parse(_ data: Data, io: CommandIO) throws -> Self {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func malformed() -> CodecError { CodecError(.malformedInput, "Invalid PNM header or raster.") }
            func space(_ c: UInt8) -> Bool { [9, 10, 11, 12, 13, 32].contains(c) }
            var cursor = 2
            func headerLimit() throws {
                guard cursor <= 16384 else { throw CodecError(.resourceLimitExceeded, "PNM header exceeds limits.") }
                try io.checkpoint()
            }
            func number(_ value: String) throws -> Int {
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { throw malformed() }
                guard let result = Int(value) else { throw CodecError(.resourceLimitExceeded, "PNM number exceeds limits.") }
                return result
            }
            func token() throws -> String {
                while cursor < bytes.count {
                    try headerLimit()
                    if space(bytes[cursor]) { cursor += 1 }
                    else if bytes[cursor] == 35 {
                        while cursor < bytes.count && bytes[cursor] != 10 {
                            cursor += 1; try headerLimit()
                        }
                    } else { break }
                }
                let start = cursor
                while cursor < bytes.count && !space(bytes[cursor]) && bytes[cursor] != 35 {
                    cursor += 1
                    guard cursor - start <= 64 else { throw CodecError(.resourceLimitExceeded, "PNM token exceeds limits.") }
                    try headerLimit()
                }
                guard cursor > start, let result = String(bytes: bytes[start..<cursor], encoding: .ascii) else { throw malformed() }
                return result
            }
            guard bytes.count >= 3, bytes[0] == 80, [53, 54, 55].contains(bytes[1]), space(bytes[2]) else { throw malformed() }
            let width: Int, height: Int, channels: Int, maximum: Int
            if bytes[1] == 55 {
                guard bytes[2] == 10 else { throw malformed() }
                cursor = 3
                var fields: [String: String] = [:], tuple = "", ended = false
                for _ in 0..<64 {
                    let start = cursor
                    while cursor < bytes.count && bytes[cursor] != 10 {
                        cursor += 1; try headerLimit()
                        guard cursor - start <= 1024 else { throw CodecError(.resourceLimitExceeded, "PAM line exceeds limits.") }
                    }
                    guard cursor < bytes.count, let line = String(bytes: bytes[start..<cursor], encoding: .ascii) else { throw malformed() }
                    cursor += 1; try headerLimit()
                    if line.hasPrefix("#") { continue }
                    let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
                    if parts.isEmpty { continue }
                    let key = String(parts[0])
                    if key == "ENDHDR" {
                        guard parts.count == 1 else { throw malformed() }
                        ended = true; break
                    }
                    if key == "TUPLTYPE" {
                        guard parts.count > 1 else { throw malformed() }
                        tuple += (tuple.isEmpty ? "" : " ") + parts.dropFirst().joined(separator: " ")
                    } else {
                        guard ["WIDTH", "HEIGHT", "DEPTH", "MAXVAL"].contains(key) else {
                            throw CodecError(.unsupportedFeature, "Unsupported PAM header field.")
                        }
                        guard parts.count == 2, fields[key] == nil else { throw malformed() }
                        fields[key] = String(parts[1])
                    }
                }
                guard ended else { throw CodecError(.resourceLimitExceeded, "PAM header line limit exceeded.") }
                guard let w = fields["WIDTH"], let h = fields["HEIGHT"],
                      let d = fields["DEPTH"], let m = fields["MAXVAL"] else { throw malformed() }
                width = try number(w); height = try number(h); channels = try number(d); maximum = try number(m)
                guard [1: "GRAYSCALE", 2: "GRAYSCALE_ALPHA", 3: "RGB", 4: "RGB_ALPHA"][channels] == tuple else {
                    throw CodecError(.unsupportedFeature, "PAM tuple type and depth must identify grey/RGB and optional straight alpha.")
                }
            } else {
                width = try number(token()); height = try number(token()); maximum = try number(token())
                channels = bytes[1] == 53 ? 1 : 3
                // Exactly one delimiter: additional whitespace or '#' can be
                // the first raster sample and must never be skipped.
                guard cursor < bytes.count, space(bytes[cursor]) else { throw malformed() }
                cursor += 1; try headerLimit()
            }
            guard width > 0, height > 0, maximum > 0, maximum <= 65535 else { throw malformed() }
            guard width <= 1024, height <= 1024 else { throw CodecError(.resourceLimitExceeded, "PNM dimensions exceed limits.") }
            guard maximum >= 255, (maximum + 1).nonzeroBitCount == 1 else {
                throw CodecError(.unsupportedFeature, "PNM requires 8–16 meaningful bits with MAXVAL equal to 2^bits-1; no rescaling.")
            }
            let bits = Int.bitWidth - maximum.leadingZeroBitCount
            // Validated dimensions, channels and precision bound this arithmetic.
            guard bytes.count - cursor == width * height * channels * (bits <= 8 ? 1 : 2) else { throw malformed() }
            if bits > 8 && bits < 16 {
                for index in stride(from: cursor, to: bytes.count, by: 2) {
                    if (index - cursor) & 2047 == 0 { try io.checkpoint() }
                    guard (Int(bytes[index]) << 8) | Int(bytes[index + 1]) <= maximum else { throw malformed() }
                }
            }
            return Self(width: width, height: height, channels: channels, bits: bits, payloadOffset: cursor)
        }
    }

    func image(_ data: Data, srgb: Bool, limits: ResourceLimits) throws -> Image {
        let roles: [ComponentRole] = (channels < 3 ? [.grey] : [.red, .green, .blue]) + (channels % 2 == 0 ? [.alpha] : [])
        let sampleBytes = bits <= 8 ? 1 : 2, stride = channels * sampleBytes
        let plane = try PlaneDescriptor(width: width, height: height, components: Array(roles.indices),
            sampleStride: sampleBytes, pixelStride: stride, rowBytes: width * stride, byteCount: width * height * stride)
        let descriptor = try ImageDescriptor(width: width, height: height, storageBits: sampleBytes * 8, meaningfulBits: bits,
            byteOrder: .bigEndian, components: roles, colour: channels < 3 ? .greyscale : .rgb,
            alpha: channels % 2 == 0 ? .straight : .absent, planes: [plane], limits: limits)
        let metadata = srgb ? ImageMetadata.empty : ImageMetadata(entries: [Self.transferKey: Data([1])], requiredKeys: [Self.transferKey])
        return try Image(descriptor: descriptor, storage: InterchangePayloadOwner(data: data, offset: payloadOffset), metadata: metadata, limits: limits)
    }

    static func requireRepresentable(_ d: ImageDescriptor, metadata: ImageMetadata, srgb: Bool) throws {
        let roles: [ComponentRole] = (d.colour == .greyscale ? [.grey] : [.red, .green, .blue]) + (d.alpha == .straight ? [.alpha] : [])
        guard d.sampleType == .unsignedInteger, (8...16).contains(d.meaningfulBits), [8, 16].contains(d.storageBits),
              [.greyscale, .rgb].contains(d.colour), [.absent, .straight].contains(d.alpha),
              d.components == roles, d.iccProfile == nil,
              metadata.entries.keys.allSatisfy({ $0 == transferKey }),
              metadata.requiredKeys.subtracting([transferKey]).isEmpty,
              (metadata.entries[transferKey] ?? Data([13])) == Data([srgb ? 13 : 1]) else {
            throw CodecError(.unsupportedFeature, "PNM cannot preserve this layout, alpha or colour metadata; select its colour variant explicitly.")
        }
    }

    static func write(_ image: Image, srgb: Bool, fd: Int32, io: CommandIO) throws {
        let d = image.descriptor
        try requireRepresentable(d, metadata: image.metadata, srgb: srgb)
        let channels = d.components.count, sampleBytes = d.meaningfulBits <= 8 ? 1 : 2
        guard d.planes.count == 1, let p = d.planes.first, p.components == Array(d.components.indices),
              p.sampleStride == d.storageBits / 8, p.pixelStride == channels * p.sampleStride else {
            throw CodecError(.incompatibleImageLayout, "PNM output requires interleaved samples.")
        }
        let maximum = (1 << d.meaningfulBits) - 1
        let header: String
        if d.alpha == .straight {
            header = "P7\nWIDTH \(d.width)\nHEIGHT \(d.height)\nDEPTH \(channels)\nMAXVAL \(maximum)\nTUPLTYPE \(channels == 2 ? "GRAYSCALE_ALPHA" : "RGB_ALPHA")\nENDHDR\n"
        } else { header = "\(channels == 1 ? "P5" : "P6")\n\(d.width) \(d.height)\n\(maximum)\n" }
        try io.writeBytes(Data(header.utf8), fd: fd)
        // One bounded serialisation row (at most 8192 bytes), covered by the
        // command overhead reservation. No second full image or file staging.
        var row = [UInt8](repeating: 0, count: d.width * channels * sampleBytes)
        try image.storage.withUnsafeBytes { bytes in
            for y in 0..<d.height {
                try io.checkpoint()
                for i in 0..<(d.width * channels) {
                    let source = p.offset + y * p.rowBytes + i * p.sampleStride
                    let first = Int(bytes[source])
                    let value = d.storageBits == 8 ? first : (d.byteOrder == .littleEndian
                        ? first | (Int(bytes[source + 1]) << 8) : (first << 8) | Int(bytes[source + 1]))
                    row[i * sampleBytes] = UInt8(truncatingIfNeeded: sampleBytes == 1 ? value : value >> 8)
                    if sampleBytes == 2 { row[i * sampleBytes + 1] = UInt8(truncatingIfNeeded: value) }
                }
                try row.withUnsafeBytes { try io.writeRaw($0, fd: fd) }
            }
        }
    }
}
