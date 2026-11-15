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

                    let r0 = UnsafeMutableRawPointer(p0)
                    let r1 = UnsafeMutableRawPointer(p1)
                    let r2 = UnsafeMutableRawPointer(p2)

                    var start = 0
                    while start < count {
                        try checkpoint()
                        let end = min(start + 1024, count)
                        var i = start
                        while i + 8 <= end {
                            let off = i &* 4
                            let vy0 = r0.loadUnaligned(fromByteOffset: off, as: SIMD8<Int32>.self)
                            let vy1 = r1.loadUnaligned(fromByteOffset: off, as: SIMD8<Int32>.self)
                            let vy2 = r2.loadUnaligned(fromByteOffset: off, as: SIMD8<Int32>.self)

                            let vs0: SIMD8<Int32>
                            let vs1: SIMD8<Int32>
                            let vs2: SIMD8<Int32>
                            switch mode {
                            case 0:
                                vs0 = vy0; vs1 = vy1; vs2 = vy2
                            case 1:
                                vs0 = vy0; vs1 = vy1; vs2 = vy2 &+ vy0
                            case 2:
                                vs0 = vy0; vs1 = vy1 &+ vy0; vs2 = vy2
                            case 3:
                                vs0 = vy0; vs1 = vy1 &+ vy0; vs2 = vy2 &+ vy0
                            case 4:
                                vs0 = vy0; vs1 = vy1 &+ ((vy0 &+ vy2) &>> 1); vs2 = vy2
                            case 5:
                                let third = vy2 &+ vy0
                                vs0 = vy0; vs1 = vy1 &+ ((vy0 &+ third) &>> 1); vs2 = third
                            default: // case 6: YCoCg-R
                                let tmp = vy0 &- (vy2 &>> 1)
                                let g = vy2 &+ tmp
                                let b = tmp &- (vy1 &>> 1)
                                let r = b &+ vy1
                                vs0 = r; vs1 = g; vs2 = b
                            }

                            switch permutation {
                            case 0:
                                r0.storeBytes(of: vs0, toByteOffset: off, as: SIMD8<Int32>.self)
                                r1.storeBytes(of: vs1, toByteOffset: off, as: SIMD8<Int32>.self)
                                r2.storeBytes(of: vs2, toByteOffset: off, as: SIMD8<Int32>.self)
                            case 1:
                                r0.storeBytes(of: vs2, toByteOffset: off, as: SIMD8<Int32>.self)
                                r1.storeBytes(of: vs0, toByteOffset: off, as: SIMD8<Int32>.self)
                                r2.storeBytes(of: vs1, toByteOffset: off, as: SIMD8<Int32>.self)
                            case 2:
                                r0.storeBytes(of: vs1, toByteOffset: off, as: SIMD8<Int32>.self)
                                r1.storeBytes(of: vs2, toByteOffset: off, as: SIMD8<Int32>.self)
                                r2.storeBytes(of: vs0, toByteOffset: off, as: SIMD8<Int32>.self)
                            case 3:
                                r0.storeBytes(of: vs0, toByteOffset: off, as: SIMD8<Int32>.self)
                                r1.storeBytes(of: vs2, toByteOffset: off, as: SIMD8<Int32>.self)
                                r2.storeBytes(of: vs1, toByteOffset: off, as: SIMD8<Int32>.self)
                            case 4:
                                r0.storeBytes(of: vs1, toByteOffset: off, as: SIMD8<Int32>.self)
                                r1.storeBytes(of: vs0, toByteOffset: off, as: SIMD8<Int32>.self)
                                r2.storeBytes(of: vs2, toByteOffset: off, as: SIMD8<Int32>.self)
                            default:
                                r0.storeBytes(of: vs2, toByteOffset: off, as: SIMD8<Int32>.self)
                                r1.storeBytes(of: vs1, toByteOffset: off, as: SIMD8<Int32>.self)
                                r2.storeBytes(of: vs0, toByteOffset: off, as: SIMD8<Int32>.self)
                            }
                            i &+= 8
                        }
                        while i < end {
                            let y0 = p0[i]
                            let y1 = p1[i]
                            let y2 = p2[i]

                            let s0: Int32
                            let s1: Int32
                            let s2: Int32
                            switch mode {
                            case 0:
                                s0 = y0
                                s1 = y1
                                s2 = y2
                            case 1:
                                s0 = y0
                                s1 = y1
                                s2 = y2 &+ y0
                            case 2:
                                s0 = y0
                                s1 = y1 &+ y0
                                s2 = y2
                            case 3:
                                s0 = y0
                                s1 = y1 &+ y0
                                s2 = y2 &+ y0
                            case 4:
                                s0 = y0
                                s1 = y1 &+ ((y0 &+ y2) >> 1)
                                s2 = y2
                            case 5:
                                let third = y2 &+ y0
                                s0 = y0
                                s1 = y1 &+ ((y0 &+ third) >> 1)
                                s2 = third
                            default: // case 6: YCoCg-R
                                let tmp = y0 &- (y2 >> 1)
                                let g = y2 &+ tmp
                                let b = tmp &- (y1 >> 1)
                                let r = b &+ y1
                                s0 = r
                                s1 = g
                                s2 = b
                            }

                            switch permutation {
                            case 0:
                                p0[i] = s0
                                p1[i] = s1
                                p2[i] = s2
                            case 1:
                                p0[i] = s2
                                p1[i] = s0
                                p2[i] = s1
                            case 2:
                                p0[i] = s1
                                p1[i] = s2
                                p2[i] = s0
                            case 3:
                                p0[i] = s0
                                p1[i] = s2
                                p2[i] = s1
                            case 4:
                                p0[i] = s1
                                p1[i] = s0
                                p2[i] = s2
                            default: // case 5
                                p0[i] = s2
                                p1[i] = s1
                                p2[i] = s0
                            }
                            i &+= 1
                        }
                        start = end
                    }
                }
            }
        }
    }
}
