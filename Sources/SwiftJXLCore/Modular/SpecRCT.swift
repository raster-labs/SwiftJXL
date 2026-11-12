// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

package enum SpecRCTError: Error, Sendable, Equatable {
    case invalidRCTType(UInt32)
    case mismatchedChannelLengths
}

/// ISO/IEC 18181-1 §8.4 inverse Reversible Colour Transform (all 42 RCT types).
package enum SpecRCT {
    package static func inverse(
        rctType: UInt32,
        channel0: inout [Int32],
        channel1: inout [Int32],
        channel2: inout [Int32],
        checkpoint: () throws -> Void
    ) throws {
        guard rctType < 42 else {
            throw SpecRCTError.invalidRCTType(rctType)
        }
        let count = channel0.count
        guard channel1.count == count, channel2.count == count else {
            throw SpecRCTError.mismatchedChannelLengths
        }
        try checkpoint()
        if count == 0 { return }

        let permutation = rctType / 7
        let mode = rctType % 7

        try channel0.withUnsafeMutableBufferPointer { buf0 in
            try channel1.withUnsafeMutableBufferPointer { buf1 in
                try channel2.withUnsafeMutableBufferPointer { buf2 in
                    let p0 = buf0.baseAddress!
                    let p1 = buf1.baseAddress!
                    let p2 = buf2.baseAddress!

                    let out0: UnsafeMutablePointer<Int32>
                    let out1: UnsafeMutablePointer<Int32>
                    let out2: UnsafeMutablePointer<Int32>
                    switch permutation {
                    case 0:
                        out0 = p0; out1 = p1; out2 = p2
                    case 1:
                        out0 = p1; out1 = p2; out2 = p0
                    case 2:
                        out0 = p2; out1 = p0; out2 = p1
                    case 3:
                        out0 = p0; out1 = p2; out2 = p1
                    case 4:
                        out0 = p1; out1 = p0; out2 = p2
                    default: // case 5
                        out0 = p2; out1 = p1; out2 = p0
                    }

                    var start = 0
                    while start < count {
                        try checkpoint()
                        let end = min(start + 1024, count)
                        switch mode {
                        case 0:
                            if permutation != 0 {
                                for i in start..<end {
                                    let y0 = p0[i], y1 = p1[i], y2 = p2[i]
                                    out0[i] = y0; out1[i] = y1; out2[i] = y2
                                }
                            }
                        case 1:
                            for i in start..<end {
                                let y0 = p0[i], y1 = p1[i], y2 = p2[i]
                                out0[i] = y0; out1[i] = y1; out2[i] = y2 &+ y0
                            }
                        case 2:
                            for i in start..<end {
                                let y0 = p0[i], y1 = p1[i], y2 = p2[i]
                                out0[i] = y0; out1[i] = y1 &+ y0; out2[i] = y2
                            }
                        case 3:
                            for i in start..<end {
                                let y0 = p0[i], y1 = p1[i], y2 = p2[i]
                                out0[i] = y0; out1[i] = y1 &+ y0; out2[i] = y2 &+ y0
                            }
                        case 4:
                            for i in start..<end {
                                let y0 = p0[i], y1 = p1[i], y2 = p2[i]
                                out0[i] = y0; out1[i] = y1 &+ ((y0 &+ y2) >> 1); out2[i] = y2
                            }
                        case 5:
                            for i in start..<end {
                                let y0 = p0[i], y1 = p1[i], y2 = p2[i]
                                let third = y2 &+ y0
                                out0[i] = y0; out1[i] = y1 &+ ((y0 &+ third) >> 1); out2[i] = third
                            }
                        default: // case 6: YCoCg-R
                            for i in start..<end {
                                let y0 = p0[i], y1 = p1[i], y2 = p2[i]
                                let tmp = y0 &- (y2 >> 1)
                                let g = y2 &+ tmp
                                let b = tmp &- (y1 >> 1)
                                let r = b &+ y1
                                out0[i] = r; out1[i] = g; out2[i] = b
                            }
                        }
                        start = end
                    }
                }
            }
        }
    }
}
