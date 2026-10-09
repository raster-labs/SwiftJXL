// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// JPEG DCT frame/component geometry: ITU-T T.81 A.1.1, A.2 and B.2.2.
import Foundation

package enum JPEGFrameError: Error, Sendable, Equatable {
    case malformed
    case unsupported
    case resourceLimit
}

/// Validated geometry for the native 8-bit DCT reconstruction path. Allocates
/// at most three component records, never coefficient or pixel storage.
package struct JPEGFrameLayout: Sendable {
    package struct Component: Sendable {
        package let id: UInt8
        package let horizontalSampling: Int
        package let verticalSampling: Int
        package let quantisationTable: UInt8
        package let visibleBlocksWide: Int
        package let visibleBlocksHigh: Int
        package let paddedBlocksWide: Int
        package let paddedBlocksHigh: Int
        package var singleComponentBlockCount: Int { visibleBlocksWide * visibleBlocksHigh }

        /// A single-component scan omits padding blocks added for interleaved
        /// MCU storage. Map its ordinal into that shared padded coefficient grid.
        package func storageIndex(forSingleComponentBlock ordinal: Int) throws -> Int {
            guard ordinal >= 0, ordinal < singleComponentBlockCount else { throw JPEGFrameError.malformed }
            return (ordinal / visibleBlocksWide) * paddedBlocksWide + ordinal % visibleBlocksWide
        }
    }

    package let marker: UInt8
    package let width: Int
    package let height: Int
    package let mcusWide: Int
    package let mcusHigh: Int
    package let components: [Component]
    package let coefficientCount: Int

    package init(data: Data, segment: JPEGSegment, maximumCoefficientBytes: Int) throws {
        guard [UInt8(0xc0), 0xc1, 0xc2].contains(segment.markerByte) else { throw JPEGFrameError.unsupported }
        let range = segment.payloadRange
        guard range.lowerBound >= 0, range.upperBound <= data.count, range.count >= 6 else {
            throw JPEGFrameError.malformed
        }
        func byte(_ n: Int) -> UInt8 { data[data.startIndex + range.lowerBound + n] }
        guard byte(0) == 8 else { throw JPEGFrameError.unsupported }
        let height = Int(byte(1)) * 256 + Int(byte(2))
        let width = Int(byte(3)) * 256 + Int(byte(4))
        let count = Int(byte(5))
        guard width > 0, height > 0 else { throw JPEGFrameError.malformed }
        guard count == 1 || count == 3 else { throw JPEGFrameError.unsupported }
        guard range.count == 6 + count * 3 else { throw JPEGFrameError.malformed }
        guard maximumCoefficientBytes > 0 else { throw JPEGFrameError.resourceLimit }
        var maxH = 1, maxV = 1
        for i in 0..<count {
            let sampling = byte(7 + i * 3)
            let h = Int(sampling >> 4), v = Int(sampling & 15)
            guard (1...4).contains(h), (1...4).contains(v), byte(8 + i * 3) < 4 else {
                throw JPEGFrameError.malformed
            }
            for j in 0..<i where byte(6 + j * 3) == byte(6 + i * 3) { throw JPEGFrameError.malformed }
            maxH = max(maxH, h); maxV = max(maxV, v)
        }
        // Header width/height <= 65535, factors <= 4: all geometry arithmetic
        // below fits Int even on 32-bit targets. The aggregate byte count uses
        // checked multiplication/addition before any coefficient allocation.
        let mcusWide = (width + 8 * maxH - 1) / (8 * maxH)
        let mcusHigh = (height + 8 * maxV - 1) / (8 * maxV)
        var components: [Component] = []
        var coefficients = 0
        for i in 0..<count {
            let h = Int(byte(7 + i * 3) >> 4), v = Int(byte(7 + i * 3) & 15)
            let bw = mcusWide * h, bh = mcusHigh * v
            let (n, overflow) = (bw * bh).multipliedReportingOverflow(by: 64)
            let (next, sumOverflow) = coefficients.addingReportingOverflow(n)
            guard !overflow, !sumOverflow, next <= maximumCoefficientBytes / MemoryLayout<Int32>.stride else {
                throw JPEGFrameError.resourceLimit
            }
            coefficients = next
            components.append(Component(id: byte(6 + i * 3), horizontalSampling: h, verticalSampling: v,
                quantisationTable: byte(8 + i * 3),
                visibleBlocksWide: (width * h + 8 * maxH - 1) / (8 * maxH),
                visibleBlocksHigh: (height * v + 8 * maxV - 1) / (8 * maxV),
                paddedBlocksWide: bw, paddedBlocksHigh: bh))
        }
        self.marker = segment.markerByte
        self.width = width; self.height = height
        self.mcusWide = mcusWide; self.mcusHigh = mcusHigh
        self.components = components; self.coefficientCount = coefficients
    }
}
