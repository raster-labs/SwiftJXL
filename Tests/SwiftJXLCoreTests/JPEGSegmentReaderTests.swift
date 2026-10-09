// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJXLCore

struct JPEGSegmentReaderTests {
    // Framing-only synthetic stream: no claim that these are decodable scans.
    private let stream = Data([
        0xff, 0xd8, 0xff, 0xff, 0xe1, 0, 4, 0x12, 0x34,
        0xff, 0xda, 0, 2, 0x71, 0xff, 0, 0x72, 0xff, 0xd0, 0x73,
        0xff, 0xff, 0xd9, 0x53, 0x54])

    @Test func preservesFillScanAndTailWithoutReparsingTail() throws {
        var reader = try JPEGSegmentReader(stream)
        let soiResult = try reader.next()
        let soi = try #require(soiResult)
        let appResult = try reader.next()
        let app = try #require(appResult)
        let scanResult = try reader.next()
        let scan = try #require(scanResult)
        let eoiResult = try reader.next()
        let eoi = try #require(eoiResult)
        #expect(soi.byteRange == 0..<2)
        #expect(app.markerRange == 2..<5)
        #expect(app.fillRange == 2..<3)
        #expect(app.payloadRange == 7..<9)
        #expect(scan.entropyRange == 13..<20)
        #expect(eoi.markerRange == 20..<23)
        #expect(reader.trailingRange == 23..<25)
        #expect(try reader.next() == nil)
        #expect(try reader.next() == nil)
        let ranges = [soi.byteRange, app.byteRange, scan.byteRange, eoi.byteRange,
                      try #require(reader.trailingRange)]
        #expect(ranges.reduce(into: Data()) { $0.append(stream[$1]) } == stream)
    }

    @Test func slicedInputHasRelativeRangesAndRetainedLifetime() throws {
        var owner = Data([9, 9, 9]) + stream
        var reader = try JPEGSegmentReader(owner.dropFirst(3))
        owner.removeAll()
        #expect(reader.data.startIndex == 3)
        var restored = Data()
        while let segment = try reader.next() {
            let base = reader.data.startIndex
            restored.append(reader.data[(base + segment.byteRange.lowerBound)..<(base + segment.byteRange.upperBound)])
        }
        let tail = try #require(reader.trailingRange)
        restored.append(reader.data[(reader.data.startIndex + tail.lowerBound)..<reader.data.endIndex])
        #expect(restored == stream)
    }

    @Test func everyPrefixBeforeEOIIsRejected() {
        for count in 0..<23 {
            #expect(throws: JPEGParseError.self) {
                var reader = try JPEGSegmentReader(Data(stream.prefix(count)))
                while try reader.next() != nil {}
            }
        }
    }

    @Test(arguments: [Data([0xff, 0xd8, 0xff, 0xe0, 0, 1]),
                      Data([0xff, 0xd8, 0xff, 0xe0, 0xff, 0xff]),
                      Data([0xff, 0xd8, 0xff, 0]),
                      Data([0xff, 0xd8, 0xff, 0xd8]),
                      Data([0xff, 0xd8, 0xff, 0xd0]),
                      Data([0xff, 0xd8, 7])])
    func malformedFramingThrows(_ data: Data) {
        #expect(throws: JPEGParseError.self) {
            var reader = try JPEGSegmentReader(data)
            while try reader.next() != nil {}
        }
    }

    @Test func multipleScansRetainEachBoundary() throws {
        var reader = try JPEGSegmentReader(Data([
            0xff, 0xd8, 0xff, 0xda, 0, 2, 7,
            0xff, 0xc4, 0, 2, 0xff, 0xda, 0, 2, 8, 0xff, 0xd9]))
        var scans: [Range<Int>] = []
        while let segment = try reader.next() {
            if segment.markerByte == 0xda { scans.append(segment.entropyRange) }
        }
        #expect(scans == [6..<7, 15..<16])
    }

    @Test func inputCountAndTimeLimitsAreEnforced() throws {
        #expect(throws: JPEGParseError.resourceLimit) { try JPEGSegmentReader(stream, maximumInputBytes: 24) }
        #expect(throws: JPEGParseError.resourceLimit) { try JPEGSegmentReader(stream, maximumSegments: 0) }
        #expect(throws: JPEGParseError.resourceLimit) {
            try JPEGSegmentReader(stream, deadline: .now.advanced(by: .seconds(-1)))
        }
        var reader = try JPEGSegmentReader(stream, maximumSegments: 1)
        _ = try reader.next()
        #expect(throws: JPEGParseError.resourceLimit) { try reader.next() }
    }

    @Test(arguments: [false, true])
    func longEntropyAndFillRunsHaveBoundedCheckpoints(_ fill: Bool) throws {
        let calls = Mutex(0)
        let bytes = Data([0xff, 0xd8, 0xff, 0xda, 0, 2])
            + Data(repeating: fill ? 0xff : 1, count: 20_000) + Data([0xff, 0xd9])
        var reader = try JPEGSegmentReader(bytes, checkpoint: {
            let count = calls.withLock { $0 += 1; return $0 }
            if count == 6 { throw CancellationError() }
        })
        _ = try reader.next()
        #expect(throws: CancellationError.self) { try reader.next() }
        #expect(calls.withLock { $0 } == 6)
    }

    @Test func taskCancellationIsHonoured() async {
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try JPEGSegmentReader(stream) }
        }.value
    }
}
