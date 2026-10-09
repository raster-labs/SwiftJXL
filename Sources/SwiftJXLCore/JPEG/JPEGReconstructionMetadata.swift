// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift JPEG/JBRDExtractor.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e. Source metadata only; never an
// original-JPEG fallback. Coefficients and quantisation belong to the JXL frame.
import Foundation

package struct JPEGReconstructionMetadata: Sendable {
    package let box: JBRDBox
    package let bundle: Data

    /// Preserve marker metadata, fill/tail bytes, scan events and entropy
    /// padding from an already validated coefficient decode. APP markers remain
    /// self-contained unknown records; no external Exif/ICC/XMP is required.
    package static func encode(_ decoded: JPEGDecodedCoefficients, policy: JBRDPolicy) throws -> Self {
        var builder = Builder(decoded: decoded, policy: policy)
        return try builder.build()
    }
}

private struct Builder {
    let decoded: JPEGDecodedCoefficients
    let policy: JBRDPolicy
    private var box = JBRDBox()
    private var budget: JBRDBudget
    private var activeQuant = [Int?](repeating: nil, count: 4)
    private var componentQuant: [Int?] = []
    private var scansRead = 0
    private var paddingRead = 0
    private var sawDRI = false

    init(decoded: JPEGDecodedCoefficients, policy: JBRDPolicy) {
        self.decoded = decoded; self.policy = policy; self.budget = JBRDBudget(policy: policy)
    }
    private func byte(_ n: Int) -> UInt8 { decoded.source[decoded.source.startIndex + n] }
    private func copy(_ range: Range<Int>) -> Data {
        Data(decoded.source[(decoded.source.startIndex + range.lowerBound)..<(decoded.source.startIndex + range.upperBound)])
    }
    private mutating func marker(_ value: UInt8) throws {
        guard box.markerOrder.count < policy.maximumMarkers else { throw JBRDError.resourceLimit }
        try budget.reserve(1, stride: 1024)
        box.markerOrder.append(value)
    }
    private func phasePolicy() throws -> JBRDPolicy {
        let remaining = policy.maximumMemoryBytes - budget.reserved
        guard remaining > 0 else { throw JBRDError.resourceLimit }
        return try JBRDPolicy(maximumInputBytes: policy.maximumInputBytes,
            maximumPayloadBytes: policy.maximumPayloadBytes, maximumMemoryBytes: remaining,
            maximumMarkers: policy.maximumMarkers, maximumEvents: policy.maximumEvents,
            maximumPaddingBits: policy.maximumPaddingBits, deadline: policy.deadline,
            checkpoint: policy.checkpoint)
    }

    mutating func build() throws -> JPEGReconstructionMetadata {
        // Charge retained source and all decoded owners before metadata copies.
        try budget.reserve(decoded.source.count, stride: 1)
        for plane in decoded.coefficients { try budget.reserve(plane.count, stride: 8) }
        try budget.reserve(decoded.padding.count, stride: 128)
        try budget.reserve(decoded.scans.count, stride: 1024)
        try budget.reserve(16384, stride: 1)
        for scan in decoded.scans {
            try budget.reserveEvents(scan.resetPoints.count)
            try budget.reserveEvents(scan.extraZeroRuns.count)
        }
        let frame = decoded.frame
        guard decoded.quantisation.count == frame.components.count else { throw JPEGEntropyError.malformed }
        box.width = frame.width; box.height = frame.height
        box.components = frame.components.map {
            JBRDComponent(id: UInt32($0.id), hSampFactor: $0.horizontalSampling,
                vSampFactor: $0.verticalSampling, widthInBlocks: UInt32($0.paddedBlocksWide),
                heightInBlocks: UInt32($0.paddedBlocksHigh))
        }
        componentQuant = frame.components.map { _ in nil }
        box.scanInfo = decoded.scans
        var reader = try JPEGSegmentReader(decoded.source, maximumInputBytes: max(1, decoded.source.count),
            maximumSegments: policy.maximumMarkers, deadline: policy.deadline, checkpoint: policy.checkpoint)
        while let segment = try reader.next() {
            try policy.checkpoint()
            if segment.markerByte == 0xd8 { continue }
            // JBRD inter-marker records are 16-bit lengths. Splitting a longer
            // fill sequence preserves its exact bytes without truncating a field.
            var fill = segment.fillRange.lowerBound
            while fill < segment.fillRange.upperBound {
                let end = fill + min(65535, segment.fillRange.upperBound - fill)
                try marker(0xff); try budget.reservePayload(end - fill)
                box.interMarkerData.append(copy(fill..<end)); fill = end
            }
            let code = segment.markerByte
            try marker(code)
            switch code {
            case 0xe0...0xef, 0xfe:
                let range = (segment.markerRange.upperBound - 1)..<segment.payloadRange.upperBound
                try budget.reservePayload(range.count)
                if code == 0xfe { box.comData.append(copy(range)) }
                else { box.appMarkerType.append(.unknown); box.appData.append(copy(range)) }
            case 0xdb: try quantisation(segment.payloadRange)
            case 0xc4: try huffman(segment.payloadRange)
            case 0xc0...0xc2: break // Already validated by the coefficient decoder.
            case 0xdd:
                // JBRD stores one interval. The reference reconstruction profile
                // rejects repeated DRI, even when coefficients remain decodable.
                guard !sawDRI else { throw JPEGEntropyError.unsupported }
                sawDRI = true
                let start = segment.payloadRange.lowerBound
                guard segment.payloadRange.count == 2 else { throw JPEGEntropyError.malformed }
                box.restartInterval = UInt32(byte(start)) * 256 + UInt32(byte(start + 1))
            case 0xda:
                guard scansRead < decoded.scans.count else { throw JPEGEntropyError.malformed }
                for component in decoded.scans[scansRead].components {
                    let ci = Int(component.compIdx)
                    guard ci < frame.components.count else { throw JPEGEntropyError.malformed }
                    if componentQuant[ci] == nil {
                        let slot = Int(frame.components[ci].quantisationTable)
                        guard let index = activeQuant[slot], box.quant[index].values == decoded.quantisation[ci].map(Int32.init) else {
                            throw JPEGEntropyError.malformed
                        }
                        componentQuant[ci] = index
                        box.components[ci].quantIdx = UInt32(index)
                    }
                }
                try checkPadding(segment.entropyRange)
                scansRead += 1
            case 0xd9: break
            default: throw JPEGEntropyError.unsupported
            }
        }
        guard scansRead == decoded.scans.count, paddingRead == decoded.padding.count,
              componentQuant.allSatisfy({ $0 != nil }), let tail = reader.trailingRange else {
            throw JPEGEntropyError.malformed
        }
        // JBRD requires its first quantisation record to be used by a
        // component. A valid JPEG may supersede that table before the first
        // scan; preserving its marker order cannot satisfy this wire profile.
        guard box.components.contains(where: { $0.quantIdx == 0 }) else { throw JPEGEntropyError.unsupported }
        guard tail.count <= 4_260_096 else { throw JBRDError.resourceLimit }
        try budget.reservePayload(tail.count); box.tailData = copy(tail)
        if !box.hasZeroPaddingBit { box.paddingBits = [] }
        // Each nested phase gets only the unreserved remainder. Header/body
        // allocations are admitted inside that phase; their retained capacity is
        // then charged before starting the next phase. No aggregate reset.
        let header = try JBRDBoxWriter.write(box, policy: phasePolicy())
        try budget.reserve(header.count, stride: 3)
        var payload = Data()
        payload.reserveCapacity(budget.payload)
        for group in [box.appData, box.comData, box.interMarkerData, [box.tailData]] {
            for bytes in group {
                var offset = 0
                while offset < bytes.count {
                    try policy.checkpoint()
                    let end = offset + min(4096, bytes.count - offset)
                    payload.append(bytes[(bytes.startIndex + offset)..<(bytes.startIndex + end)])
                    offset = end
                }
            }
        }
        guard header.count < policy.maximumInputBytes else { throw JBRDError.resourceLimit }
        let body = try BrotliEncoder.encodeUncompressed(payload,
            policy: BrotliPolicy(maximumInputBytes: max(1, policy.maximumPayloadBytes),
                maximumOutputBytes: policy.maximumInputBytes - header.count,
                maximumMemoryBytes: phasePolicy().maximumMemoryBytes,
                deadline: policy.deadline, checkpoint: policy.checkpoint))
        try budget.reserve(body.count, stride: 3)
        // Header and body already fit the compressed ceiling; subtraction avoids
        // overflow when callers choose extreme resource limits.
        guard body.count <= policy.maximumInputBytes - header.count else { throw JBRDError.resourceLimit }
        try budget.reserve(header.count, stride: 3); try budget.reserve(body.count, stride: 3)
        var bundle = header; bundle.append(body)
        try policy.checkpoint()
        return JPEGReconstructionMetadata(box: box, bundle: bundle)
    }

    private mutating func checkPadding(_ entropy: Range<Int>) throws {
        var finished = false
        while paddingRead < decoded.padding.count {
            try policy.checkpoint()
            let value = decoded.padding[paddingRead]
            guard (0...7).contains(value.bitCount), value.offset >= entropy.lowerBound,
                  value.offset <= entropy.upperBound else { throw JPEGEntropyError.malformed }
            if value.offset < entropy.upperBound {
                // Redundant FF fill before a restart cannot be placed in a JBRD
                // inter-marker record: it is inside this scan's entropy data.
                guard entropy.upperBound - value.offset >= 2, byte(value.offset) == 0xff,
                      (0xd0...0xd7).contains(byte(value.offset + 1)) else { throw JPEGEntropyError.unsupported }
            } else { finished = true }
            guard value.bitCount <= policy.maximumPaddingBits - box.paddingBits.count else { throw JBRDError.resourceLimit }
            try budget.reserve(value.bitCount, stride: 4)
            for bit in (0..<value.bitCount).reversed() {
                let v = (value.bits >> bit) & 1
                box.paddingBits.append(v)
                box.hasZeroPaddingBit = box.hasZeroPaddingBit || v == 0
            }
            paddingRead += 1
            if finished { break }
        }
        guard finished else { throw JPEGEntropyError.malformed }
    }

    private mutating func quantisation(_ range: Range<Int>) throws {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            try policy.checkpoint()
            guard box.quant.count < 3 else { throw JPEGEntropyError.unsupported }
            let info = byte(cursor); cursor += 1
            let precision = Int(info >> 4), slot = Int(info & 15)
            guard precision <= 1, slot < 4, range.upperBound - cursor >= 64 * (precision + 1) else { throw JPEGEntropyError.malformed }
            try budget.reserve(64, stride: 16)
            var values = [Int32](repeating: 0, count: 64)
            for k in 0..<64 {
                var value = Int32(byte(cursor)); cursor += 1
                if precision == 1 { value = value * 256 + Int32(byte(cursor)); cursor += 1 }
                guard value > 0 else { throw JPEGEntropyError.malformed }
                values[JPEGZigZag.order[k]] = value
            }
            activeQuant[slot] = box.quant.count
            box.quant.append(JBRDQuantTable(precision: UInt32(precision), index: UInt32(slot),
                isLast: cursor == range.upperBound, values: values))
        }
    }

    private mutating func huffman(_ range: Range<Int>) throws {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            try policy.checkpoint()
            guard box.huffmanCode.count < 89 else { throw JBRDError.resourceLimit }
            guard range.upperBound - cursor >= 17 else { throw JPEGEntropyError.malformed }
            let slot = Int(byte(cursor)); cursor += 1
            try budget.reserve(257 + 17, stride: 16)
            var counts = [UInt32](repeating: 0, count: 17), total = 0, last = 0
            for length in 1...16 {
                counts[length] = UInt32(byte(cursor)); cursor += 1
                total += Int(counts[length]); if counts[length] > 0 { last = length }
            }
            guard last > 0, total <= 256, total <= range.upperBound - cursor else { throw JPEGEntropyError.malformed }
            var values = (0..<total).map { UInt32(byte(cursor + $0)) }; cursor += total
            counts[last] += 1; values.append(256)
            box.huffmanCode.append(JBRDHuffmanCode(counts: counts, values: values, slotId: slot,
                                                 isLast: cursor == range.upperBound))
        }
    }
}
