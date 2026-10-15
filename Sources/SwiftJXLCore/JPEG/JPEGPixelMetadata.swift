// SPDX-License-Identifier: Apache-2.0
// JPEG ICC APP2 framing and Exif TIFF interpretation. Profiles are retained,
// never display-converted. All offsets are relative to the owning payload.
import Foundation

package struct JPEGPixelMetadata: Sendable {
    package var iccProfile: Data?
    package var exif: Data?
    package var orientation = 1
    package var exifSRGB = false
    package private(set) var discardedAncillary: Data?
    private struct Discard: Sendable {
        let marker: Int
        var count: Int
        var payloadBytes: Int
    }
    private var discards: [Discard] = []

    /// At most sixteen APP kinds, COM and trailing data. Retains only counters,
    /// never discarded bytes, offsets, annotations or other source payload.
    package mutating func recordDiscard(marker: UInt8?, payloadBytes: Int,
                                        budget: ScalarOperationBudget) throws {
        let kind = marker.map(Int.init) ?? 256
        guard payloadBytes >= 0, kind == 256 || kind == 254 || (224...239).contains(kind) else {
            throw JPEGEntropyError.malformed
        }
        if discards.isEmpty {
            // Eighteen fixed-size counters, bounded textual serialisation and
            // capacity overlap. Reserve before allocating this report state.
            try budget.reserveWorkspace(32 * 1024)
        }
        if let i = discards.firstIndex(where: { $0.marker == kind }) {
            discards[i].count = try ScalarOperationBudget.sum(discards[i].count, 1)
            discards[i].payloadBytes = try ScalarOperationBudget.sum(discards[i].payloadBytes, payloadBytes)
        } else {
            guard discards.count < 18 else { throw JPEGEntropyError.resourceLimit }
            discards.append(Discard(marker: kind, count: 1, payloadBytes: payloadBytes))
        }
    }
    package mutating func finishDiscardSummary() {
        guard !discards.isEmpty else { return }
        let items = discards.sorted(by: { $0.marker < $1.marker }).map { item in
            let kind = item.marker == 256 ? "trailingData" : item.marker == 254 ? "COM" : "APP\(item.marker - 224)"
            return "{\"kind\":\"\(kind)\",\"count\":\(item.count),\"payloadBytes\":\(item.payloadBytes)}"
        }
        discardedAncillary = Data(("{\"version\":1,\"items\":[" + items.joined(separator: ",") + "]}").utf8)
    }
    private var fragments: [Int: Range<Int>] = [:]
    private var fragmentCount = 0
    private var fragmentBytes = 0

    package mutating func addICC(_ range: Range<Int>, source: Data, maximumBytes: Int) throws {
        guard range.count >= 14 else { throw JPEGEntropyError.malformed }
        let index = Int(source[source.startIndex + range.lowerBound + 12])
        let count = Int(source[source.startIndex + range.lowerBound + 13])
        guard index > 0, index <= count, fragments[index] == nil,
              fragmentCount == 0 || fragmentCount == count else { throw JPEGEntropyError.malformed }
        let body = (range.lowerBound + 14)..<range.upperBound
        guard body.count <= maximumBytes - fragmentBytes else { throw JPEGEntropyError.resourceLimit }
        fragmentBytes += body.count; fragmentCount = count; fragments[index] = body
    }
    package mutating func finishICC(source: Data, components: Int, budget: ScalarOperationBudget) throws {
        guard fragmentCount > 0 else { return }
        guard fragments.count == fragmentCount else { throw JPEGEntropyError.malformed }
        try budget.reserveWorkspace(ScalarOperationBudget.product(fragmentBytes, 3))
        var profile = Data(); profile.reserveCapacity(fragmentBytes)
        for i in 1...fragmentCount {
            try budget.checkpoint()
            guard let r = fragments[i] else { throw JPEGEntropyError.malformed }
            profile.append(source[(source.startIndex + r.lowerBound)..<(source.startIndex + r.upperBound)])
        }
        func integer(_ p: Int) throws -> Int {
            guard p >= 0, p <= profile.count, 4 <= profile.count - p else { throw JPEGEntropyError.malformed }
            let value = profile[p..<p + 4].reduce(UInt32(0), { ($0 << 8) | UInt32($1) })
            guard let result = Int(exactly: value) else { throw JPEGEntropyError.resourceLimit }
            return result
        }
        guard profile.count >= 132, try integer(0) == profile.count,
              profile[36..<40] == Data("acsp".utf8) else { throw JPEGEntropyError.malformed }
        guard profile[16..<20] == Data((components == 1 ? "GRAY" : "RGB ").utf8),
              [Data("XYZ ".utf8), Data("Lab ".utf8)].contains(profile[20..<24]) else { throw JPEGEntropyError.unsupported }
        let count = try integer(128)
        guard count <= (profile.count - 132) / 12 else { throw JPEGEntropyError.malformed }
        for i in 0..<count {
            try budget.checkpoint()
            let offset = try integer(136 + i * 12), size = try integer(140 + i * 12)
            guard offset >= 132 + 12 * count, offset <= profile.count, size <= profile.count - offset else { throw JPEGEntropyError.malformed }
        }
        iccProfile = profile
    }

    package mutating func addExif(_ payload: Data, maximumDepth: Int, budget: ScalarOperationBudget) throws {
        guard exif == nil, payload.count >= 14, payload.prefix(6) == Data("Exif\0\0".utf8) else { throw JPEGEntropyError.malformed }
        try budget.reserveWorkspace(ScalarOperationBudget.product(payload.count, 3))
        let tiff = 6, count = payload.count - tiff
        guard payload[6..<8] == Data([73, 73]) || payload[6..<8] == Data([77, 77]) else { throw JPEGEntropyError.malformed }
        let little = payload[6] == 73
        func integer(_ offset: Int, _ size: Int) throws -> Int {
            guard offset >= 0, offset <= count, size <= count - offset else { throw JPEGEntropyError.malformed }
            var value: UInt32 = 0
            for i in 0..<size { value |= UInt32(payload[tiff + offset + i]) << ((little ? i : size - 1 - i) * 8) }
            guard let result = Int(exactly: value) else { throw JPEGEntropyError.resourceLimit }
            return result
        }
        guard try integer(2, 2) == 42 else { throw JPEGEntropyError.malformed }
        let root = try integer(4, 4)
        guard root >= 8 else { throw JPEGEntropyError.malformed }
        // Follow the primary, Exif, GPS and interoperability IFD pointers and
        // thumbnail chain. Unknown entries remain verbatim required metadata.
        var pending = [(root, 0, 0)], visited = Set<Int>(), totalEntries = 0
        var colour: Int?, orientation = 1
        while let (offset, depth, role) = pending.popLast() {
            try budget.checkpoint()
            guard depth < min(maximumDepth, 32) else { throw JPEGEntropyError.resourceLimit }
            guard visited.insert(offset).inserted else { throw JPEGEntropyError.malformed }
            let entries = try integer(offset, 2)
            guard entries <= 4096 - totalEntries else { throw JPEGEntropyError.resourceLimit }
            guard offset <= count - 2, entries <= (count - offset - 2) / 12 else { throw JPEGEntropyError.malformed }
            totalEntries += entries
            var tags = Set<Int>()
            for i in 0..<entries {
                try budget.checkpoint()
                let p = offset + 2 + i * 12
                let tag = try integer(p, 2), type = try integer(p + 2, 2), n = try integer(p + 4, 4)
                guard tags.insert(tag).inserted else { throw JPEGEntropyError.malformed }
                let sizes = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8]
                guard type > 0, type < sizes.count, n <= count / sizes[type] else { throw JPEGEntropyError.malformed }
                let size = n * sizes[type], value = size <= 4 ? p + 8 : try integer(p + 8, 4)
                guard value <= count, size <= count - value else { throw JPEGEntropyError.malformed }
                if role == 0 && tag == 0x112 {
                    guard type == 3, n == 1 else { throw JPEGEntropyError.malformed }
                    orientation = try integer(value, 2)
                    guard (1...8).contains(orientation) else { throw JPEGEntropyError.malformed }
                }
                if role == 1 && tag == 0xa001 {
                    guard type == 3, n == 1, colour == nil else { throw JPEGEntropyError.malformed }
                    colour = try integer(value, 2)
                }
                // Nonstandard YCbCr interpretation requires a separate colour
                // conversion contract. Preserve other tags without guessing it.
                if role == 0 && [0x211, 0x214].contains(tag) { throw JPEGEntropyError.unsupported }
                if [0x8769, 0x8825, 0xa005].contains(tag) {
                    guard (role == 0 && tag != 0xa005) || (role == 1 && tag == 0xa005) else { throw JPEGEntropyError.unsupported }
                    guard type == 4, n == 1 else { throw JPEGEntropyError.malformed }
                    let child = try integer(value, 4)
                    guard child >= 8 else { throw JPEGEntropyError.malformed }
                    pending.append((child, depth + 1, tag == 0x8769 ? 1 : 2))
                }
            }
            let next = try integer(offset + 2 + entries * 12, 4)
            if next != 0 { pending.append((next, depth + 1, 3)) }
        }
        guard colour == nil || colour == 1 || colour == 65535 else { throw JPEGEntropyError.unsupported }
        self.exif = payload; self.orientation = orientation; self.exifSRGB = colour == 1
    }
    /// Keep source TIFF and its geometry untouched as provenance. The caller
    /// stores this under jpeg.sourceExif when pixels are explicitly reoriented;
    /// jpeg.orientation describes the actual published raster independently.
    package var sourceExif: Data? { exif }
}
