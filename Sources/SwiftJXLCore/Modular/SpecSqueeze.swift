// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// ISO/IEC 18181-1 §8.5 inverse Squeeze transform (horizontal and vertical Haar lifting with smooth tendency).
package enum SpecSqueeze {
    @inline(__always)
    private static func smoothTendency(_ b: Int64, _ a: Int64, _ n: Int64) -> Int64 {
        var diff: Int64 = 0
        if b >= a && a >= n {
            diff = (4 * b - 3 * n - a + 6) / 12
            if diff - (diff & 1) > 2 * (b - a) {
                diff = 2 * (b - a) + 1
            }
            if diff + (diff & 1) > 2 * (a - n) {
                diff = 2 * (a - n)
            }
        } else if b <= a && a <= n {
            diff = (4 * b - 3 * n - a - 6) / 12
            if diff + (diff & 1) < 2 * (b - a) {
                diff = 2 * (b - a) - 1
            }
            if diff - (diff & 1) < 2 * (a - n) {
                diff = 2 * (a - n)
            }
        }
        return diff
    }

    package static func inverse(
        ll: ModularChannel,
        residual: ModularChannel,
        horizontal: Bool,
        budget: ScalarOperationBudget
    ) throws -> ModularChannel {
        guard ll.pixels.count == ll.sampleCount,
              residual.pixels.count == residual.sampleCount,
              ll.hshift == residual.hshift,
              ll.vshift == residual.vshift else {
            throw ModularGeometryError.invalidSqueeze
        }

        let outWidth: Int
        let outHeight: Int
        let outHShift: Int
        let outVShift: Int

        if horizontal {
            guard ll.height == residual.height,
                  ll.width >= residual.width,
                  ll.width <= residual.width + 1 else {
                throw ModularGeometryError.invalidSqueeze
            }
            let (w, over) = ll.width.addingReportingOverflow(residual.width)
            guard !over else { throw ModularGeometryError.invalidDimensions }
            outWidth = w
            outHeight = ll.height
            outHShift = ll.hshift > 0 ? ll.hshift - 1 : ll.hshift
            outVShift = ll.vshift
        } else {
            guard ll.width == residual.width,
                  ll.height >= residual.height,
                  ll.height <= residual.height + 1 else {
                throw ModularGeometryError.invalidSqueeze
            }
            let (h, over) = ll.height.addingReportingOverflow(residual.height)
            guard !over else { throw ModularGeometryError.invalidDimensions }
            outWidth = ll.width
            outHeight = h
            outHShift = ll.hshift
            outVShift = ll.vshift > 0 ? ll.vshift - 1 : ll.vshift
        }

        var output = try ModularChannel(
            width: outWidth,
            height: outHeight,
            hshift: outHShift,
            vshift: outVShift
        )
        try output.allocatePixels(budget: budget)
        if output.sampleCount == 0 {
            return output
        }

        try ll.pixels.withUnsafeBufferPointer { lowBuf in
            try residual.pixels.withUnsafeBufferPointer { highBuf in
                try output.pixels.withUnsafeMutableBufferPointer { outBuf in
                    let lowBase = lowBuf.baseAddress!
                    let highBase = highBuf.baseAddress!
                    let outBase = outBuf.baseAddress!

                    if horizontal {
                        let wLow = ll.width
                        let wHigh = residual.width
                        for y in 0..<outHeight {
                            try budget.checkpoint()
                            let lowRow = y * wLow
                            let highRow = y * wHigh
                            let outRow = y * outWidth
                            for x in 0..<wHigh {
                                if (x & 1023) == 0, x > 0 { try budget.checkpoint() }
                                let a = Int64(lowBase[lowRow + x])
                                let b = x > 0 ? Int64(outBase[outRow + 2 * x - 1]) : a
                                let n = (x + 1 < wLow) ? Int64(lowBase[lowRow + x + 1]) : a
                                let tendency = smoothTendency(b, a, n)
                                let diff = Int64(highBase[highRow + x]) + tendency
                                let first = a + (diff / 2)
                                let second = first - diff
                                outBase[outRow + 2 * x] = Int32(truncatingIfNeeded: first)
                                outBase[outRow + 2 * x + 1] = Int32(truncatingIfNeeded: second)
                            }
                            if outWidth > 2 * wHigh {
                                outBase[outRow + 2 * wHigh] = lowBase[lowRow + wHigh]
                            }
                        }
                    } else {
                        let hLow = ll.height
                        let hHigh = residual.height
                        let w = outWidth
                        for y in 0..<hHigh {
                            try budget.checkpoint()
                            let rowCur = y * w
                            let rowNext = (y + 1 < hLow ? (y + 1) : y) * w
                            let outRowPrev = (2 * y - 1) * w
                            let outRow0 = (2 * y) * w
                            let outRow1 = (2 * y + 1) * w
                            for x in 0..<w {
                                if (x & 1023) == 0, x > 0 { try budget.checkpoint() }
                                let a = Int64(lowBase[rowCur + x])
                                let b = y > 0 ? Int64(outBase[outRowPrev + x]) : a
                                let n = Int64(lowBase[rowNext + x])
                                let tendency = smoothTendency(b, a, n)
                                let diff = Int64(highBase[rowCur + x]) + tendency
                                let first = a + (diff / 2)
                                let second = first - diff
                                outBase[outRow0 + x] = Int32(truncatingIfNeeded: first)
                                outBase[outRow1 + x] = Int32(truncatingIfNeeded: second)
                            }
                        }
                        if outHeight > 2 * hHigh {
                            try budget.checkpoint()
                            let lowTail = hHigh * w
                            let outTail = (2 * hHigh) * w
                            for x in 0..<w {
                                outBase[outTail + x] = lowBase[lowTail + x]
                            }
                        }
                    }
                }
            }
        }

        return output
    }
}
