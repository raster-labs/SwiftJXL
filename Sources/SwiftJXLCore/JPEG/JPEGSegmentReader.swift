// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift JPEGSegmentReader.swift at 57e81cb9e2411d1efac435b429a306a031744c1e.
// JPEG marker/entropy framing: ITU-T T.81 B.1.1.2 and F.1.2.3.
import Foundation

package enum JPEGParseError: Error, Sendable, Equatable {
    case missingSOI
    case truncated(at: Int)
    case invalidSegmentLength(marker: UInt8, length: Int)
    case expectedMarkerPrefix(at: Int)
    case unexpectedMarker(UInt8)
    case resourceLimit
}

/// Offsets are relative to the retained input's first byte, including sliced Data.
/// A record preserves fill bytes and the entire following scan (stuffing and
/// restart markers included). It performs no entropy or frame validity check.
package struct JPEGSegment: Sendable, Equatable {
    package let markerByte: UInt8
    package let markerRange: Range<Int>
    package let payloadRange: Range<Int>
    package let entropyRange: Range<Int>
    package var byteRange: Range<Int> { markerRange.lowerBound..<entropyRange.upperBound }
    package var fillRange: Range<Int> { markerRange.lowerBound..<(markerRange.upperBound - 2) }
}

/// Forward-only, constant-workspace framing reader. Retains the original Data
/// owner; does not allocate arrays of segments or copy marker/entropy payloads.
/// Callers must charge the retained input and any collected records to their
/// operation budget. Returned ranges are meaningful only with this input owner.
package struct JPEGSegmentReader: Sendable {
    package let data: Data
    private var position = 0
    private var segmentCount = 0
    private var ended = false
    private let maximumSegments: Int
    private let deadline: ContinuousClock.Instant
    private let checkpoint: @Sendable () throws -> Void
    package private(set) var trailingRange: Range<Int>?

    package init(_ data: Data, maximumInputBytes: Int = 64 * 1024 * 1024,
                 maximumSegments: Int = 4096,
                 deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(10)),
                 checkpoint: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }) throws {
        guard maximumInputBytes > 0, maximumSegments > 0,
              data.count <= maximumInputBytes else { throw JPEGParseError.resourceLimit }
        self.data = data
        self.maximumSegments = maximumSegments
        self.deadline = deadline
        self.checkpoint = checkpoint
        try check()
        guard data.count >= 2, byte(0) == 0xff, byte(1) == 0xd8 else {
            throw JPEGParseError.missingSOI
        }
    }

    package mutating func next() throws -> JPEGSegment? {
        try check()
        if ended { return nil }
        guard segmentCount < maximumSegments else { throw JPEGParseError.resourceLimit }
        let start = position
        let marker = try readMarker()
        let markerEnd = position
        guard !(marker == 0xd8 && start != 0), !(0xd0...0xd7).contains(marker) else {
            throw JPEGParseError.unexpectedMarker(marker)
        }
        segmentCount += 1
        if marker == 0xd9 {
            ended = true
            trailingRange = position..<data.count
        }
        if marker == 0xd8 || marker == 0xd9 || marker == 0x01 {
            return JPEGSegment(markerByte: marker, markerRange: start..<markerEnd,
                               payloadRange: position..<position, entropyRange: position..<position)
        }
        guard data.count - position >= 2 else { throw JPEGParseError.truncated(at: position) }
        let length = Int(byte(position)) * 256 + Int(byte(position + 1))
        guard length >= 2 else { throw JPEGParseError.invalidSegmentLength(marker: marker, length: length) }
        guard length <= data.count - position else { throw JPEGParseError.truncated(at: position) }
        let payload = (position + 2)..<(position + length)
        position += length
        let entropyStart = position
        if marker == 0xda { try skipEntropy() }
        return JPEGSegment(markerByte: marker, markerRange: start..<markerEnd,
                           payloadRange: payload, entropyRange: entropyStart..<position)
    }

    private func byte(_ offset: Int) -> UInt8 { data[data.startIndex + offset] }

    private func check() throws {
        try checkpoint()
        guard ContinuousClock.now < deadline else { throw JPEGParseError.resourceLimit }
    }

    private mutating func readMarker() throws -> UInt8 {
        guard position < data.count else { throw JPEGParseError.truncated(at: position) }
        guard byte(position) == 0xff else { throw JPEGParseError.expectedMarkerPrefix(at: position) }
        while position < data.count, byte(position) == 0xff {
            if position & 4095 == 0 { try check() }
            position += 1
        }
        guard position < data.count else { throw JPEGParseError.truncated(at: position) }
        let marker = byte(position)
        guard marker != 0 else { throw JPEGParseError.expectedMarkerPrefix(at: position) }
        position += 1
        return marker
    }

    private mutating func skipEntropy() throws {
        while position < data.count {
            if position & 4095 == 0 { try check() }
            if byte(position) != 0xff { position += 1; continue }
            let start = position
            let marker = try entropyMarker()
            if marker == 0 || (0xd0...0xd7).contains(marker) { continue }
            position = start
            return
        }
        throw JPEGParseError.truncated(at: position)
    }

    // Unlike readMarker, FF00 belongs to the entropy representation. Preserve
    // these bytes verbatim; the later entropy decoder validates scan semantics.
    private mutating func entropyMarker() throws -> UInt8 {
        while position < data.count, byte(position) == 0xff {
            if position & 4095 == 0 { try check() }
            position += 1
        }
        guard position < data.count else { throw JPEGParseError.truncated(at: position) }
        let marker = byte(position)
        position += 1
        return marker
    }
}
