// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift 57e81cb9e2411d1efac435b429a306a031744c1e, Sources/JXLSwift/Container/JXLContainer.swift.
// JPEG XL container format (ISO/IEC 18181-2).
//
// A `.jxl` file may take one of two forms:
//
//   1. A "naked codestream" starting with the 2-byte signature
//      `FF 0A`. Used for the simplest cases — no metadata, single
//      animation frame, no JPEG reconstruction support.
//
//   2. An ISOBMFF container starting with the signature box:
//
//          00 00 00 0C  J X L (space)  0D 0A 87 0A
//
//      followed by a stream of boxes:
//
//          • ftyp       file-type box (always present)
//          • jxll       JXL level (optional)
//          • jxli       frame-index (optional)
//          • Exif       EXIF metadata (optional)
//          • xml        XMP metadata (optional)
//          • jbrd       JPEG bitstream reconstruction (optional)
//          • jxlc       complete codestream (when small enough)
//                       — OR —
//          • jxlp x N   partial codestream chunks (large files)
//          • jxll       container-level metadata
//          • brob       Brotli-compressed metadata
//
// Each box is `[size: u32 BE][type: 4 ASCII][payload …]`. A size of 0
// means "extends to end of file"; size 1 means an extended 8-byte size
// follows the type field. See ISO/IEC 14496-12 §4.2 for the underlying
// rules.

import Foundation

package enum ContainerError: Error, Equatable, Sendable {
    case truncated(String)
    case missingSignature
    case missingFTYP
    case unsupportedExtendedSize
    case malformedBox(String)
}

/// A parsed ISOBMFF box from a JXL container.
package struct JXLBox: Sendable, Equatable {
    /// 4-character ASCII box type (`jxlc`, `jxlp`, `Exif`, `xml `, …).
    package let type: String
    /// Byte range of the payload within the original buffer (does not
    /// include the box header).
    package let payloadRange: Range<Int>

    package init(type: String, payloadRange: Range<Int>) {
        self.type = type
        self.payloadRange = payloadRange
    }
}

/// The 12-byte JXL container signature box (always at offset 0 when the
/// file is in container form).
package let jxlContainerSignature: [UInt8] = [
    0x00, 0x00, 0x00, 0x0C,       // box size = 12
    0x4A, 0x58, 0x4C, 0x20,       // 'JXL '
    0x0D, 0x0A, 0x87, 0x0A        // codestream marker
]

/// The 2-byte naked-codestream signature.
package let jxlCodestreamSignature: [UInt8] = [0xFF, 0x0A]

/// Whether `data` looks like a JXL byte stream (either naked codestream
/// or ISOBMFF container).
package func isJXL(_ data: Data) -> Bool {
    if data.count >= 2 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0x0A {
        return true
    }
    if data.count >= 12 {
        for i in 0..<12 where data[data.startIndex + i] != jxlContainerSignature[i] {
            return false
        }
        return true
    }
    return false
}

package enum JXLContainerForm: Sendable, Equatable {
    /// Naked codestream — the entire file IS the codestream.
    case naked
    /// ISOBMFF container with a list of boxes.
    case iso(boxes: [JXLBox])
}

/// Parse a JXL byte stream into either a naked codestream or a list of
/// ISOBMFF boxes. Does not validate codestream contents.
package func parseJXLContainer(_ data: Data) throws -> JXLContainerForm {
    guard data.count >= 2 else {
        throw ContainerError.truncated("file too small to be JXL")
    }

    // Naked codestream?
    if data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0x0A {
        return .naked
    }

    // ISOBMFF: must start with the 12-byte signature box.
    guard data.count >= 12 else {
        throw ContainerError.missingSignature
    }
    for i in 0..<12 where data[data.startIndex + i] != jxlContainerSignature[i] {
        throw ContainerError.missingSignature
    }

    var cursor = 12
    var boxes: [JXLBox] = []
    while cursor < data.count {
        guard cursor + 8 <= data.count else {
            throw ContainerError.truncated("partial box header at offset \(cursor)")
        }
        let sizeRaw = uint32BigEndian(data, offset: cursor)
        let typeBytes = data.subdata(in: (data.startIndex + cursor + 4)..<(data.startIndex + cursor + 8))
        guard let type = String(data: typeBytes, encoding: .ascii) else {
            throw ContainerError.malformedBox("non-ASCII box type at offset \(cursor)")
        }
        let payloadStart: Int
        let boxEnd: Int
        switch sizeRaw {
        case 0:
            // Extends to end of file.
            payloadStart = cursor + 8
            boxEnd = data.count
        case 1:
            // 8-byte extended size follows.
            guard cursor + 16 <= data.count else {
                throw ContainerError.truncated("extended-size box header at offset \(cursor)")
            }
            let extSize = uint64BigEndian(data, offset: cursor + 8)
            guard extSize >= 16 && extSize <= UInt64(data.count - cursor) else {
                throw ContainerError.unsupportedExtendedSize
            }
            payloadStart = cursor + 16
            boxEnd = cursor + Int(extSize)
        default:
            guard sizeRaw >= 8 else {
                throw ContainerError.malformedBox("size \(sizeRaw) < 8 at offset \(cursor)")
            }
            payloadStart = cursor + 8
            guard UInt64(sizeRaw) <= UInt64(data.count - cursor) else {
                throw ContainerError.truncated("Box extends past input")
            }
            boxEnd = cursor + Int(sizeRaw)
        }
        guard boxEnd <= data.count else {
            throw ContainerError.truncated("box '\(type)' extends past EOF")
        }
        guard boxes.count < 4096 else { throw ContainerError.malformedBox("Too many boxes") }
        boxes.append(JXLBox(type: type, payloadRange: payloadStart..<boxEnd))
        cursor = boxEnd
    }
    guard boxes.first?.type == "ftyp", boxes.filter({ $0.type == "ftyp" }).count == 1 else {
        throw ContainerError.missingFTYP
    }
    return .iso(boxes: boxes)
}

/// Locate and concatenate the codestream from a parsed container.
/// Looks for a single `jxlc` box or a sequence of `jxlp` partials.
package func extractCodestream(from boxes: [JXLBox], in data: Data) throws -> Data {
    let complete = boxes.filter { $0.type == "jxlc" }
    if let jxlc = complete.first {
        guard complete.count == 1, !boxes.contains(where: { $0.type == "jxlp" }) else {
            throw ContainerError.malformedBox("Mixed or repeated codestream boxes")
        }
        return data.subdata(in: (data.startIndex + jxlc.payloadRange.lowerBound)..<(data.startIndex + jxlc.payloadRange.upperBound))
    }
    let partials = boxes.filter { $0.type == "jxlp" }
    guard !partials.isEmpty else {
        throw ContainerError.malformedBox("container has no jxlc or jxlp box")
    }
    // Each `jxlp` payload begins with a 4-byte big-endian sequence number;
    // the high bit (0x8000_0000) indicates the final partial. Sort by
    // sequence and concatenate the rest.
    var ordered: [(seq: UInt32, range: Range<Int>, last: Bool)] = []
    for box in partials {
        guard box.payloadRange.count >= 4 else {
            throw ContainerError.malformedBox("jxlp box too small")
        }
        let raw = uint32BigEndian(data, offset: box.payloadRange.lowerBound)
        let seq = raw & 0x7FFF_FFFF
        let last = (raw & 0x8000_0000) != 0
        let payload = (box.payloadRange.lowerBound + 4)..<box.payloadRange.upperBound
        ordered.append((seq, payload, last))
    }
    ordered.sort { $0.seq < $1.seq }
    var combined = Data()
    for (index, part) in ordered.enumerated() {
        guard part.seq == UInt32(index), part.last == (index == ordered.count - 1) else {
            throw ContainerError.malformedBox("Invalid partial codestream sequence")
        }
        let range = (data.startIndex + part.range.lowerBound)..<(data.startIndex + part.range.upperBound)
        combined.append(data.subdata(in: range))
    }
    return combined
}

@inline(__always)
private func uint32BigEndian(_ data: Data, offset: Int) -> UInt32 {
    let b0 = UInt32(data[data.startIndex + offset])
    let b1 = UInt32(data[data.startIndex + offset + 1])
    let b2 = UInt32(data[data.startIndex + offset + 2])
    let b3 = UInt32(data[data.startIndex + offset + 3])
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

@inline(__always)
private func uint64BigEndian(_ data: Data, offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<8 {
        value = (value << 8) | UInt64(data[data.startIndex + offset + i])
    }
    return value
}
