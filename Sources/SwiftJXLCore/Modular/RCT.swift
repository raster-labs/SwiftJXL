// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift 57e81cb9e2411d1efac435b429a306a031744c1e, Sources/JXLSwift/Modular/RCT.swift.
// RCT — reversible colour transform for the Modular sub-codec.
//
// ISO/IEC 18181-1 §C.7.7. The Modular path can decorrelate colour
// channels by applying a small bijective integer transform before
// prediction. For typical photographic / medical-imaging RGB the R,
// G, and B channels are highly correlated (a brightness change tends
// to shift all three by similar amounts); after RCT the dominant
// channel carries the brightness signal and the remaining channels
// carry small differences that prediction-then-entropy can compress
// to close to nothing.
//
// **What this file implements:**
//
// `RCTVariant.ycocgR`: the lossless YCoCg-R transform —
//
//     forward:                          inverse:
//       Co  = R - B                       tmp = Y - (Cg >> 1)
//       tmp = B + (Co >> 1)               G   = Cg + tmp
//       Cg  = G - tmp                     B   = tmp - (Co >> 1)
//       Y   = tmp + (Cg >> 1)             R   = B + Co
//
// This is the standard YCoCg-R reversible variant — exact integer
// round-trip with one bit of bit-depth growth on the chroma channels
// (Co and Cg can be negative). We carry pixel data as `Int32`
// throughout so the growth is absorbed without overflow.
//
// **Caveat:** the JPEG XL spec defines several RCT variants (§C.7.7
// `rct_type` 0..6). YCoCg-R is one of them but the spec's variant
// numbering / selection encoding requires spec text I don't yet
// have. This file ships YCoCg-R as a project-internal primitive
// that's mathematically lossless and round-trip-tested; the
// numbering and encoding need spec verification before it can
// participate in a JXL-spec-compliant codestream.
//
// **Composes with:** the existing prediction pipeline. The intended
// use is: pixels → RCT.forward → per-channel predictor selection →
// residuals → entropy. Inverse applied after pixel reconstruction.

import Foundation

/// Identifies a specific reversible colour transform.
package enum RCTVariant: UInt32, Sendable, Equatable, CaseIterable {
    /// Identity — channels pass through unchanged. Useful as the
    /// "RCT disabled" baseline.
    case identity = 0
    /// YCoCg-R reversible variant. Three channels in, three out;
    /// inputs are R, G, B (in the order channels are presented);
    /// outputs are Y, Co, Cg respectively in slots 0, 1, 2.
    case ycocgR   = 1
}

package enum RCT {

    /// Apply the forward transform to a 3-channel pixel triple.
    /// `(r, g, b)` → `(y, co, cg)`. Inputs and outputs are `Int32`.
    /// Identity passes through unchanged; YCoCg-R applies the
    /// formulas at the top of the file.
    @inline(__always)
    package static func forwardPixel(
        _ variant: RCTVariant, r: Int32, g: Int32, b: Int32
    ) -> (Int32, Int32, Int32) {
        switch variant {
        case .identity:
            return (r, g, b)
        case .ycocgR:
            let co  = r &- b
            let tmp = b &+ (co &>> 1)
            let cg  = g &- tmp
            let y   = tmp &+ (cg &>> 1)
            return (y, co, cg)
        }
    }

    /// Inverse of `forwardPixel(_:r:g:b:)`. `(y, co, cg)` → `(r, g, b)`.
    @inline(__always)
    package static func inversePixel(
        _ variant: RCTVariant, y: Int32, co: Int32, cg: Int32
    ) -> (Int32, Int32, Int32) {
        switch variant {
        case .identity:
            return (y, co, cg)
        case .ycocgR:
            let tmp = y &- (cg &>> 1)
            let g   = cg &+ tmp
            let b   = tmp &- (co &>> 1)
            let r   = b &+ co
            return (r, g, b)
        }
    }

    /// Apply the forward transform to three flat row-major channel
    /// buffers in-place, replacing them with the transformed
    /// channels. All three buffers must be the same length.
    package static func forward(
        _ variant: RCTVariant,
        channel0: inout [Int32], channel1: inout [Int32], channel2: inout [Int32]
    ) {
        precondition(
            channel0.count == channel1.count && channel1.count == channel2.count,
            "RCT requires channels of equal length"
        )
        if variant == .identity { return }
        let count = channel0.count
        channel0.withUnsafeMutableBufferPointer { b0 in
            channel1.withUnsafeMutableBufferPointer { b1 in
                channel2.withUnsafeMutableBufferPointer { b2 in
                    guard let p0 = b0.baseAddress, let p1 = b1.baseAddress, let p2 = b2.baseAddress else { return }
                    let r0 = UnsafeMutableRawPointer(p0)
                    let r1 = UnsafeMutableRawPointer(p1)
                    let r2 = UnsafeMutableRawPointer(p2)
                    var i = 0
                    while i + 8 <= count {
                        let off = i &* 4
                        let vr = r0.loadUnaligned(fromByteOffset: off, as: SIMD8<Int32>.self)
                        let vg = r1.loadUnaligned(fromByteOffset: off, as: SIMD8<Int32>.self)
                        let vb = r2.loadUnaligned(fromByteOffset: off, as: SIMD8<Int32>.self)
                        let co  = vr &- vb
                        let tmp = vb &+ (co &>> 1)
                        let cg  = vg &- tmp
                        let y   = tmp &+ (cg &>> 1)
                        r0.storeBytes(of: y, toByteOffset: off, as: SIMD8<Int32>.self)
                        r1.storeBytes(of: co, toByteOffset: off, as: SIMD8<Int32>.self)
                        r2.storeBytes(of: cg, toByteOffset: off, as: SIMD8<Int32>.self)
                        i &+= 8
                    }
                    while i < count {
                        let (a, b, c) = forwardPixel(variant, r: p0[i], g: p1[i], b: p2[i])
                        p0[i] = a; p1[i] = b; p2[i] = c
                        i &+= 1
                    }
                }
            }
        }
    }

    /// Apply the inverse transform to three flat row-major channel
    /// buffers in-place.
    package static func inverse(
        _ variant: RCTVariant,
        channel0: inout [Int32], channel1: inout [Int32], channel2: inout [Int32]
    ) {
        precondition(
            channel0.count == channel1.count && channel1.count == channel2.count,
            "RCT requires channels of equal length"
        )
        if variant == .identity { return }
        let count = channel0.count
        channel0.withUnsafeMutableBufferPointer { b0 in
            channel1.withUnsafeMutableBufferPointer { b1 in
                channel2.withUnsafeMutableBufferPointer { b2 in
                    guard let p0 = b0.baseAddress, let p1 = b1.baseAddress, let p2 = b2.baseAddress else { return }
                    let r0 = UnsafeMutableRawPointer(p0)
                    let r1 = UnsafeMutableRawPointer(p1)
                    let r2 = UnsafeMutableRawPointer(p2)
                    var i = 0
                    while i + 8 <= count {
                        let off = i &* 4
                        let vy  = r0.loadUnaligned(fromByteOffset: off, as: SIMD8<Int32>.self)
                        let vco = r1.loadUnaligned(fromByteOffset: off, as: SIMD8<Int32>.self)
                        let vcg = r2.loadUnaligned(fromByteOffset: off, as: SIMD8<Int32>.self)
                        let tmp = vy &- (vcg &>> 1)
                        let g   = vcg &+ tmp
                        let b   = tmp &- (vco &>> 1)
                        let r   = b &+ vco
                        r0.storeBytes(of: r, toByteOffset: off, as: SIMD8<Int32>.self)
                        r1.storeBytes(of: g, toByteOffset: off, as: SIMD8<Int32>.self)
                        r2.storeBytes(of: b, toByteOffset: off, as: SIMD8<Int32>.self)
                        i &+= 8
                    }
                    while i < count {
                        let (a, b, c) = inversePixel(variant, y: p0[i], co: p1[i], cg: p2[i])
                        p0[i] = a; p1[i] = b; p2[i] = c
                        i &+= 1
                    }
                }
            }
        }
    }
}
