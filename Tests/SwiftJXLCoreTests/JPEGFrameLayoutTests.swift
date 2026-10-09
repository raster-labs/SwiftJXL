// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct JPEGFrameLayoutTests {
    @Test(arguments: ["gray", "444", "422", "420", "440", "progressive", "restart", "metadata-tail", "fill-marker"])
    func pinnedIndependentFixtures(_ name: String) throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jpg", subdirectory: "JPEG"))
        let data = try Data(contentsOf: url)
        var reader = try JPEGSegmentReader(data)
        var cursor = 0, frames = 0, scans = 0, fillBytes = 0
        while let segment = try reader.next() {
            #expect(segment.byteRange.lowerBound == cursor)
            cursor = segment.byteRange.upperBound
            fillBytes += segment.fillRange.count
            if segment.markerByte == 0xda { scans += 1 }
            if [UInt8(0xc0), 0xc1, 0xc2].contains(segment.markerByte) {
                let frame = try JPEGFrameLayout(data: data, segment: segment, maximumCoefficientBytes: 64 * 1024)
                frames += 1
                #expect(frame.width == 31 && frame.height == 17)
                #expect(frame.components.count == (name == "gray" ? 1 : 3))
                if name == "progressive" {
                    let luma = try #require(frame.components.first)
                    #expect(frame.marker == 0xc2)
                    #expect(luma.paddedBlocksWide == 4 && luma.paddedBlocksHigh == 4)
                    #expect(luma.visibleBlocksWide == 4 && luma.visibleBlocksHigh == 3)
                    #expect(luma.singleComponentBlockCount == 12)
                    #expect(try luma.storageIndex(forSingleComponentBlock: 11) == 11)
                    #expect(throws: JPEGFrameError.malformed) { try luma.storageIndex(forSingleComponentBlock: 12) }
                }
                #expect(throws: JPEGFrameError.resourceLimit) {
                    try JPEGFrameLayout(data: data, segment: segment, maximumCoefficientBytes: 1)
                }
            }
        }
        #expect(frames == 1)
        #expect(scans == (name == "progressive" ? 10 : 1))
        #expect(fillBytes == (name == "fill-marker" ? 1 : 0))
        #expect(reader.trailingRange == cursor..<data.count)
        #expect(data.count - cursor == (name == "metadata-tail" ? 14 : 0))
    }

    @Test func nonInterleavedIndicesSkipRightAndBottomPadding() throws {
        // 17x17, 4:2:0. Interleaved Y grid is 4x4; visible scan is 3x3.
        let data = Data([8, 0, 17, 0, 17, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1])
        let segment = JPEGSegment(markerByte: 0xc2, markerRange: 0..<2,
                                  payloadRange: 0..<data.count, entropyRange: data.count..<data.count)
        let frame = try JPEGFrameLayout(data: data, segment: segment, maximumCoefficientBytes: 6144)
        let y = try #require(frame.components.first)
        #expect(try (0..<9).map { try y.storageIndex(forSingleComponentBlock: $0) } == [0, 1, 2, 4, 5, 6, 8, 9, 10])
        #expect(frame.coefficientCount == 1536)
        #expect(throws: JPEGFrameError.resourceLimit) {
            try JPEGFrameLayout(data: data, segment: segment, maximumCoefficientBytes: 6143)
        }
    }

    @Test func malformedAndUnsupportedFramesRejectBeforeAllocation() {
        let valid = Data([8, 0, 17, 0, 17, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1])
        var variants = (0..<valid.count).map { Data(valid.prefix($0)) }
        for (index, value): (Int, UInt8) in [(0, 12), (5, 4), (7, 0), (7, 0x51), (8, 4), (9, 1)] {
            var changed = valid; changed[index] = value; variants.append(changed)
        }
        for data in variants {
            let segment = JPEGSegment(markerByte: 0xc2, markerRange: 0..<2,
                payloadRange: 0..<data.count, entropyRange: data.count..<data.count)
            #expect(throws: JPEGFrameError.self) {
                try JPEGFrameLayout(data: data, segment: segment, maximumCoefficientBytes: Int.max)
            }
        }
    }
}
