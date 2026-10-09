// SPDX-License-Identifier: Apache-2.0
// Adapted from JXLSwift 57e81cb9e2411d1efac435b429a306a031744c1e,
// Sources/JXLSwift/Brotli/BrotliMetaBlock.swift; corrected against RFC 7932 §9.

struct BrotliMetaBlockHeader: Equatable {
    enum Kind: Equatable { case empty, metadata, uncompressed, compressed }
    let isLast: Bool
    let kind: Kind
    /// Output length for data blocks; skip length for metadata; zero for empty.
    let length: Int
}

enum BrotliMetaBlockReader {
    static func readWindowBits(from reader: inout BrotliReader) throws -> Int {
        if try !reader.readBit() { return 16 }
        let m = Int(try reader.read(bits: 3))
        if m != 0 { return 17 + m }
        let n = Int(try reader.read(bits: 3))
        if n == 0 { return 17 }
        guard n != 1 else { throw BrotliError.malformed("Reserved window size") }
        return 8 + n
    }

    /// Leaves raw/metadata payloads byte-aligned; compressed bodies remain bit-aligned.
    static func read(from reader: inout BrotliReader) throws -> BrotliMetaBlockHeader {
        let last = try reader.readBit()
        if last, try reader.readBit() {
            return BrotliMetaBlockHeader(isLast: true, kind: .empty, length: 0)
        }
        let raw = Int(try reader.read(bits: 2))
        if raw == 3 {
            guard try !reader.readBit() else { throw BrotliError.malformed("Reserved metadata bit") }
            let bytes = Int(try reader.read(bits: 2))
            let value = Int(try reader.read(bits: bytes * 8))
            guard bytes <= 1 || value >> ((bytes - 1) * 8) != 0 else {
                throw BrotliError.malformed("Noncanonical metadata length")
            }
            try reader.alignToByte()
            return BrotliMetaBlockHeader(isLast: last, kind: .metadata,
                                        length: bytes == 0 ? 0 : value + 1)
        }
        let nibbles = raw + 4
        let value = Int(try reader.read(bits: nibbles * 4))
        guard nibbles == 4 || value >> ((nibbles - 1) * 4) != 0 else {
            throw BrotliError.malformed("Noncanonical meta-block length")
        }
        let uncompressed = try !last && reader.readBit()
        if uncompressed { try reader.alignToByte() }
        return BrotliMetaBlockHeader(isLast: last,
                                    kind: uncompressed ? .uncompressed : .compressed,
                                    length: value + 1)
    }
}
