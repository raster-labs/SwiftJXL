// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Modular/SpecSqueeze.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors' algorithm retains BSD-3-Clause terms;
// see Documentation/ThirdParty/libjxl-LICENSE.txt.

package enum SpecSqueeze {
    /// Inputs are widened Int32 samples, so these Int64 intermediates cannot
    /// overflow. Division intentionally truncates towards zero, not -infinity.
    @inline(__always)
    private static func smoothTendency(B: Int64, a: Int64, n: Int64) -> Int64 {
        var diff: Int64 = 0
        if B >= a && a >= n {
            diff = (4 * B - 3 * n - a + 6) / 12
            if diff - (diff & 1) > 2 * (B - a) { diff = 2 * (B - a) + 1 }
            if diff + (diff & 1) > 2 * (a - n) { diff = 2 * (a - n) }
        } else if B <= a && a <= n {
            diff = (4 * B - 3 * n - a - 6) / 12
            if diff + (diff & 1) < 2 * (B - a) { diff = 2 * (B - a) - 1 }
            if diff - (diff & 1) < 2 * (a - n) { diff = 2 * (a - n) }
        }
        return diff
    }

    /// Validate paired geometry and complete planes before allocating output.
    /// Meta-channel shifts (-1) stay meta; normal shifts must be reversible.
    package static func inverse(ll: ModularChannel, residual: ModularChannel,
                                horizontal: Bool, budget: ScalarOperationBudget) throws -> ModularChannel {
        try budget.checkpoint()
        try ll.checkPixels(); try residual.checkPixels()
        guard ll.hshift == residual.hshift, ll.vshift == residual.vshift,
              ll.width > 0, ll.height > 0 else { throw ModularGeometryError.invalidGeometry }
        let low = horizontal ? ll.width : ll.height
        let high = horizontal ? residual.width : residual.height
        let shift = horizontal ? ll.hshift : ll.vshift
        guard (horizontal ? ll.height == residual.height : ll.width == residual.width),
              high <= low, low - high <= 1, shift == -1 || shift > 0 else {
            throw ModularGeometryError.invalidGeometry
        }
        let combined = try ScalarOperationBudget.sum(low, high)
        var out = try ModularChannel(width: horizontal ? combined : ll.width,
            height: horizontal ? ll.height : combined,
            hshift: horizontal && shift > 0 ? shift - 1 : ll.hshift,
            vshift: !horizontal && shift > 0 ? shift - 1 : ll.vshift)
        try out.allocatePixels(budget: budget)
        // Borrowed storage stays within these synchronous closures. Geometry
        // proves all offsets below fit sampleCount; the only callback is the
        // budget's cancellation/deadline check, which cannot re-enter a plane.
        try ll.pixels.withUnsafeBufferPointer { lowPixels in
            try residual.pixels.withUnsafeBufferPointer { highPixels in
                try out.pixels.withUnsafeMutableBufferPointer { pixels in
                    if horizontal {
                        for y in 0..<ll.height {
                            try budget.checkpoint()
                            let loRow = y * ll.width, hiRow = y * residual.width, row = y * out.width
                            for x in 0..<high {
                                if x & 1023 == 0 { try budget.checkpoint() }
                                let avg = Int64(lowPixels[loRow + x])
                                let next = x + 1 < low ? Int64(lowPixels[loRow + x + 1]) : avg
                                let left = x > 0 ? Int64(pixels[row + 2 * x - 1]) : avg
                                let diff = Int64(highPixels[hiRow + x]) + smoothTendency(B: left, a: avg, n: next)
                                let a = avg + diff / 2
                                pixels[row + 2 * x] = Int32(truncatingIfNeeded: a)
                                pixels[row + 2 * x + 1] = Int32(truncatingIfNeeded: a - diff)
                            }
                            if combined & 1 != 0 { pixels[row + combined - 1] = lowPixels[loRow + low - 1] }
                        }
                    } else {
                        for y in 0..<high {
                            try budget.checkpoint()
                            let loRow = y * ll.width, row = 2 * y * ll.width
                            for x in 0..<ll.width {
                                if x & 1023 == 0 { try budget.checkpoint() }
                                let avg = Int64(lowPixels[loRow + x])
                                let next = y + 1 < low ? Int64(lowPixels[loRow + ll.width + x]) : avg
                                let top = y > 0 ? Int64(pixels[row - ll.width + x]) : avg
                                let diff = Int64(highPixels[loRow + x]) + smoothTendency(B: top, a: avg, n: next)
                                let a = avg + diff / 2
                                pixels[row + x] = Int32(truncatingIfNeeded: a)
                                pixels[row + ll.width + x] = Int32(truncatingIfNeeded: a - diff)
                            }
                        }
                        if combined & 1 != 0 {
                            for x in 0..<ll.width {
                                if x & 1023 == 0 { try budget.checkpoint() }
                                pixels[(combined - 1) * ll.width + x] = lowPixels[(low - 1) * ll.width + x]
                            }
                        }
                    }
                }
            }
        }
        try budget.checkpoint()
        return out
    }
}
