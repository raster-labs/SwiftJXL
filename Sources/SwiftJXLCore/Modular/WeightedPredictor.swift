// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift 57e81cb9e2411d1efac435b429a306a031744c1e, Sources/JXLSwift/Modular/WeightedPredictor.swift.
// WeightedPredictor — stateful per-pixel weighted predictor for the
// Modular sub-codec.
//
// ISO/IEC 18181-1 §C.7.5 / libjxl `lib/jxl/modular/encoding/
// context_predict.h::weighted::State`. The weighted predictor is a
// learned mixer of 4 sub-predictors:
//
//   sub[0] = W + NE - N
//   sub[1] = N - ((teN + teW + teNE) * p1C) >> 5
//   sub[2] = W - ((teN + teW + teNW) * p2C) >> 5
//   sub[3] = N - (teNW*p3Ca + teN*p3Cb + teNE*p3Cc + (NN-N)*p3Cd
//                 + (NW-W)*p3Ce) >> 5
//
// where `teX` is the *signed prediction error* at neighbour pixel X
// from this row (or the previous row, swapped via `y & 1`). The four
// predictions are combined via `WeightedAverage` using per-predictor
// weights derived from the running absolute-error tally `pred_errors`.
//
// **Per-pixel state** (kept across an entire channel decode):
//   • `predErrors[4][2 * (xsize+2)]` — per-sub-predictor running
//     absolute-error sums. Two rows; we toggle which row is "current"
//     via `y & 1`.
//   • `error[2 * (xsize+2)]` — signed (pred - actual) errors per pixel.
//   • `prediction[4]` — the four sub-predictor outputs for the most
//     recent pixel (read by `wpResult`).
//   • `pred` — the combined weighted prediction *before* shift-back.
//
// **Output of `predict(...)`** is the final scalar prediction at
// `(x, y)` — already shifted back from the kPredExtraBits=3 fixed-
// point representation. The caller adds the leaf's `predictorOffset`
// and the residual on top, then must call `update(actual:x:y:xsize:)`
// to fold the actual decoded pixel value into the running error
// estimates.
//
// **Property 15 (kWPProp)** is `max(|teW|, |teN|, |teNW|, |teNE|)` —
// the largest absolute prediction error seen at the four neighbours.
// `propertyValue(...)` returns it without advancing state, for the
// MA-tree decision pass.
//
// **Internal pixel-arithmetic width**: we use `Int64` throughout the
// weighted-predictor body — `pred * weights[i]` can multiply up to
// 14-bit predictions by 16-bit weights, so the safe accumulator type
// is at least 32 bits; libjxl uses `pixel_type_w = int64_t`. Match it.

import Foundation

/// Stateful weighted predictor matching libjxl `weighted::State`.
/// Construct once per channel, call `predict` then `update` per pixel
/// in row-major order. Mutating across calls (the running error
/// arrays evolve as pixels are decoded).
package struct WeightedPredictor: Sendable {
    package static let kPredExtraBits: Int = 3
    package static let kPredictionRound: Int64 = (Int64(1) << kPredExtraBits) >> 1 - 1
    package static let kNumPredictors: Int = 4

    /// 1 << 24 / (i + 1) for i in 0..<64 — division-avoidance LUT.
    package static let divLookup: [UInt32] = [
        16777216, 8388608, 5592405, 4194304, 3355443, 2796202, 2396745, 2097152,
        1864135,  1677721, 1525201, 1398101, 1290555, 1198372, 1118481, 1048576,
        986895,   932067,  883011,  838860,  798915,  762600,  729444,  699050,
        671088,   645277,  621378,  599186,  578524,  559240,  541200,  524288,
        508400,   493447,  479349,  466033,  453438,  441505,  430185,  419430,
        409200,   399457,  390167,  381300,  372827,  364722,  356962,  349525,
        342392,   335544,  328965,  322638,  316551,  310689,  305040,  299593,
        294337,   289262,  284359,  279620,  275036,  270600,  266305,  262144
    ]

    package let header: WeightedPredictorHeader
    private let stride: Int  // (xsize + 2) — per-row span in error/predErrors.
    private let planeSize: Int           // 2 * stride — one predictor's span.
    private var predErrors: [SIMD4<UInt32>] // [2 * stride] vectors of 4 sub-predictor error sums.
    private var error: [Int64]           // [2 * stride]
    // Last-pixel sub-predictions (read back by `update`). Scalars, not an
    // array: these are touched per pixel and array storage cost a
    // uniqueness check + bounds check per access.
    private var p0: Int64 = 0, p1: Int64 = 0, p2: Int64 = 0, p3: Int64 = 0
    private var pred: Int64              // last combined pred (shifted-up domain).

    package init(header: WeightedPredictorHeader, xsize: Int) {
        self.header = header
        self.stride = xsize + 2
        let total = 2 * stride
        self.planeSize = total
        self.predErrors = [SIMD4<UInt32>](repeating: .zero, count: total)
        self.error = [Int64](repeating: 0, count: total)
        self.pred = 0
    }

    /// Add `kPredExtraBits` of fractional precision (libjxl
    /// `AddBits(x) = x << 3`).
    @inline(__always)
    private static func addBits(_ x: Int64) -> Int64 { x &<< Int64(kPredExtraBits) }

    /// `4 + (maxweight << 24) / (x + 1)` approximation. Matches libjxl
    /// `ErrorWeight`.
    @inline(__always)
    private static func errorWeight(
        _ x: UInt64, maxWeight: UInt32, divLut: UnsafePointer<UInt32>
    ) -> UInt32 {
        let xp1 = x &+ 1
        let log2: Int = xp1 == 0 ? 0 : Int(63 &- xp1.leadingZeroBitCount)
        let shift = max(0, log2 &- 5)
        let lookupIdx = Int((x &>> shift) & 0x3F)
        let div = divLut[lookupIdx]
        return 4 &+ ((maxWeight &* div) &>> shift)
    }

    /// Combine four sub-predictions via per-predictor weights using
    /// libjxl's division-avoiding `WeightedAverage`.
    @inline(__always)
    private static func weightedAverage(
        _ q0: Int64, _ q1: Int64, _ q2: Int64, _ q3: Int64,
        _ wIn: (UInt32, UInt32, UInt32, UInt32),
        divLut: UnsafePointer<UInt32>
    ) -> Int64 {
        var w0 = wIn.0, w1 = wIn.1, w2 = wIn.2, w3 = wIn.3
        var weightSum: UInt32 = w0 &+ w1 &+ w2 &+ w3
        // Spec / libjxl invariant: weightSum > 15 (each w[i] is 4..16).
        let logWeight: UInt32 = weightSum == 0 ? 0
            : UInt32(31 &- weightSum.leadingZeroBitCount)
        let shift = UInt32(max(0, Int(logWeight) &- 4))
        w0 &>>= shift; w1 &>>= shift; w2 &>>= shift; w3 &>>= shift
        weightSum = w0 &+ w1 &+ w2 &+ w3
        var sum: Int64 = Int64(weightSum &>> 1) &- 1
        sum &+= q0 &* Int64(w0)
        sum &+= q1 &* Int64(w1)
        sum &+= q2 &* Int64(w2)
        sum &+= q3 &* Int64(w3)
        let lookupIdx = Int(weightSum &- 1) & 0x3F
        let div = Int64(divLut[lookupIdx])
        return (sum &* div) &>> 24
    }

    /// Scoped per-channel borrow of `predErrors`, `error`, and `divLookup` that
    /// avoids per-pixel array COW checks and static array retain/release.
    package struct Borrowed {
        let header: WeightedPredictorHeader
        let stride: Int
        let predErrors: UnsafeMutablePointer<SIMD4<UInt32>>
        let error: UnsafeMutablePointer<Int64>
        let divLut: UnsafePointer<UInt32>
        var p0: Int64
        var p1: Int64
        var p2: Int64
        var p3: Int64
        var pred: Int64

        @inline(__always)
        package func propertyValue(x: Int, y: Int, xsize: Int) -> Int32 {
            let curRowOff  = (y & 1 == 1) ? 0 : stride
            let prevRowOff = (y & 1 == 1) ? stride : 0
            let posN  = prevRowOff &+ x
            let posNE = (x < xsize &- 1) ? posN &+ 1 : posN
            let posNW = (x > 0) ? posN &- 1 : posN
            let teW: Int64 = (x == 0) ? 0 : error[curRowOff &+ x &- 1]
            let teN: Int64 = error[posN]
            let teNW: Int64 = error[posNW]
            let teNE: Int64 = error[posNE]
            var p: Int64 = teW
            if abs(teN)  > abs(p) { p = teN }
            if abs(teNW) > abs(p) { p = teNW }
            if abs(teNE) > abs(p) { p = teNE }
            return Int32(truncatingIfNeeded: p)
        }

        @inline(__always)
        package mutating func predict(
            x: Int, y: Int, xsize: Int,
            n: Int32, w: Int32, ne: Int32, nw: Int32, nn: Int32
        ) -> Int32 {
            let curRowOff  = (y & 1 == 1) ? 0 : stride
            let prevRowOff = (y & 1 == 1) ? stride : 0
            let posN  = prevRowOff &+ x
            let posNE = (x < xsize &- 1) ? posN &+ 1 : posN
            let posNW = (x > 0) ? posN &- 1 : posN

            let peN = predErrors[posN]
            let peNE = predErrors[posNE]
            let peNW = predErrors[posNW]
            let weights: (UInt32, UInt32, UInt32, UInt32) = (
                WeightedPredictor.errorWeight(
                    UInt64(peN[0]) &+ UInt64(peNE[0]) &+ UInt64(peNW[0]),
                    maxWeight: header.weights.0,
                    divLut: divLut
                ),
                WeightedPredictor.errorWeight(
                    UInt64(peN[1]) &+ UInt64(peNE[1]) &+ UInt64(peNW[1]),
                    maxWeight: header.weights.1,
                    divLut: divLut
                ),
                WeightedPredictor.errorWeight(
                    UInt64(peN[2]) &+ UInt64(peNE[2]) &+ UInt64(peNW[2]),
                    maxWeight: header.weights.2,
                    divLut: divLut
                ),
                WeightedPredictor.errorWeight(
                    UInt64(peN[3]) &+ UInt64(peNE[3]) &+ UInt64(peNW[3]),
                    maxWeight: header.weights.3,
                    divLut: divLut
                )
            )

            let nB = WeightedPredictor.addBits(Int64(n))
            let wB = WeightedPredictor.addBits(Int64(w))
            let neB = WeightedPredictor.addBits(Int64(ne))
            let nwB = WeightedPredictor.addBits(Int64(nw))
            let nnB = WeightedPredictor.addBits(Int64(nn))

            let teW: Int64 = (x == 0) ? 0 : error[curRowOff &+ x &- 1]
            let teN: Int64 = error[posN]
            let teNW: Int64 = error[posNW]
            let sumWN: Int64 = teN &+ teW
            let teNE: Int64 = error[posNE]

            p0 = wB &+ neB &- nB
            p1 = nB &- (((sumWN &+ teNE) &* Int64(header.p1C)) &>> 5)
            p2 = wB &- (((sumWN &+ teNW) &* Int64(header.p2C)) &>> 5)
            p3 = nB &- ((teNW &* Int64(header.p3Ca)
                       &+ teN  &* Int64(header.p3Cb)
                       &+ teNE &* Int64(header.p3Cc)
                       &+ (nnB &- nB) &* Int64(header.p3Cd)
                       &+ (nwB &- wB) &* Int64(header.p3Ce)) &>> 5)

            pred = WeightedPredictor.weightedAverage(p0, p1, p2, p3, weights, divLut: divLut)

            let mixed = (teN ^ teW) | (teN ^ teNW)
            if mixed <= 0 {
                let mx = max(wB, max(neB, nB))
                let mn = min(wB, min(neB, nB))
                if pred > mx { pred = mx }
                if pred < mn { pred = mn }
            }
            let shifted = (pred &+ WeightedPredictor.kPredictionRound)
                              &>> Int64(WeightedPredictor.kPredExtraBits)
            return Int32(truncatingIfNeeded: shifted)
        }

        @inline(__always)
        package mutating func update(actual: Int32, x: Int, y: Int, xsize: Int) {
            let curRowOff = (y & 1 == 1) ? 0 : stride
            let prevRowOff = (y & 1 == 1) ? stride : 0
            let valShifted = WeightedPredictor.addBits(Int64(actual))
            let cur = curRowOff &+ x
            error[cur] = pred &- valShifted
            let round = WeightedPredictor.kPredictionRound
            let shift = Int64(WeightedPredictor.kPredExtraBits)
            let e0 = UInt32(truncatingIfNeeded: (abs(p0 &- valShifted) &+ round) &>> shift)
            let e1 = UInt32(truncatingIfNeeded: (abs(p1 &- valShifted) &+ round) &>> shift)
            let e2 = UInt32(truncatingIfNeeded: (abs(p2 &- valShifted) &+ round) &>> shift)
            let e3 = UInt32(truncatingIfNeeded: (abs(p3 &- valShifted) &+ round) &>> shift)
            let errVec = SIMD4<UInt32>(e0, e1, e2, e3)
            predErrors[cur] = errVec
            if x &+ 1 < stride {
                predErrors[prevRowOff &+ x &+ 1] &+= errVec
            }
        }

        /// Fused predict + update for encoding loops where `actual` is already known.
        @inline(__always)
        package mutating func predictAndUpdate(
            actual: Int32,
            x: Int, y: Int, xsize: Int,
            n: Int32, w: Int32, ne: Int32, nw: Int32, nn: Int32
        ) -> Int32 {
            let curRowOff  = (y & 1 == 1) ? 0 : stride
            let prevRowOff = (y & 1 == 1) ? stride : 0
            let posN  = prevRowOff &+ x
            let posNE = (x < xsize &- 1) ? posN &+ 1 : posN
            let posNW = (x > 0) ? posN &- 1 : posN

            let peN = predErrors[posN]
            let peNE = predErrors[posNE]
            let peNW = predErrors[posNW]
            let weights: (UInt32, UInt32, UInt32, UInt32) = (
                WeightedPredictor.errorWeight(
                    UInt64(peN[0]) &+ UInt64(peNE[0]) &+ UInt64(peNW[0]),
                    maxWeight: header.weights.0,
                    divLut: divLut
                ),
                WeightedPredictor.errorWeight(
                    UInt64(peN[1]) &+ UInt64(peNE[1]) &+ UInt64(peNW[1]),
                    maxWeight: header.weights.1,
                    divLut: divLut
                ),
                WeightedPredictor.errorWeight(
                    UInt64(peN[2]) &+ UInt64(peNE[2]) &+ UInt64(peNW[2]),
                    maxWeight: header.weights.2,
                    divLut: divLut
                ),
                WeightedPredictor.errorWeight(
                    UInt64(peN[3]) &+ UInt64(peNE[3]) &+ UInt64(peNW[3]),
                    maxWeight: header.weights.3,
                    divLut: divLut
                )
            )

            let nB = WeightedPredictor.addBits(Int64(n))
            let wB = WeightedPredictor.addBits(Int64(w))
            let neB = WeightedPredictor.addBits(Int64(ne))
            let nwB = WeightedPredictor.addBits(Int64(nw))
            let nnB = WeightedPredictor.addBits(Int64(nn))

            let cur = curRowOff &+ x
            let teW: Int64 = (x == 0) ? 0 : error[cur &- 1]
            let teN: Int64 = error[posN]
            let teNW: Int64 = error[posNW]
            let sumWN: Int64 = teN &+ teW
            let teNE: Int64 = error[posNE]

            let q0 = wB &+ neB &- nB
            let q1 = nB &- (((sumWN &+ teNE) &* Int64(header.p1C)) &>> 5)
            let q2 = wB &- (((sumWN &+ teNW) &* Int64(header.p2C)) &>> 5)
            let q3 = nB &- ((teNW &* Int64(header.p3Ca)
                       &+ teN  &* Int64(header.p3Cb)
                       &+ teNE &* Int64(header.p3Cc)
                       &+ (nnB &- nB) &* Int64(header.p3Cd)
                       &+ (nwB &- wB) &* Int64(header.p3Ce)) &>> 5)

            var combined = WeightedPredictor.weightedAverage(q0, q1, q2, q3, weights, divLut: divLut)

            let mixed = (teN ^ teW) | (teN ^ teNW)
            if mixed <= 0 {
                let mx = max(wB, max(neB, nB))
                let mn = min(wB, min(neB, nB))
                if combined > mx { combined = mx }
                if combined < mn { combined = mn }
            }
            let round = WeightedPredictor.kPredictionRound
            let shift = Int64(WeightedPredictor.kPredExtraBits)
            let prediction = Int32(truncatingIfNeeded: (combined &+ round) &>> shift)

            let valShifted = WeightedPredictor.addBits(Int64(actual))
            error[cur] = combined &- valShifted
            let e0 = UInt32(truncatingIfNeeded: (abs(q0 &- valShifted) &+ round) &>> shift)
            let e1 = UInt32(truncatingIfNeeded: (abs(q1 &- valShifted) &+ round) &>> shift)
            let e2 = UInt32(truncatingIfNeeded: (abs(q2 &- valShifted) &+ round) &>> shift)
            let e3 = UInt32(truncatingIfNeeded: (abs(q3 &- valShifted) &+ round) &>> shift)
            let errVec = SIMD4<UInt32>(e0, e1, e2, e3)
            predErrors[cur] = errVec
            if x &+ 1 < stride {
                predErrors[posN &+ 1] &+= errVec
            }
            p0 = q0; p1 = q1; p2 = q2; p3 = q3; pred = combined
            return prediction
        }
    }

    package mutating func withBuffers<R>(_ body: (inout Borrowed) throws -> R) rethrows -> R {
        let hdr = header, st = stride
        var localP0 = p0, localP1 = p1, localP2 = p2, localP3 = p3, localPred = pred
        defer {
            p0 = localP0; p1 = localP1; p2 = localP2; p3 = localP3; pred = localPred
        }
        return try WeightedPredictor.divLookup.withUnsafeBufferPointer { divPtr in
            try predErrors.withUnsafeMutableBufferPointer { pePtr in
                try error.withUnsafeMutableBufferPointer { errPtr in
                    var b = Borrowed(
                        header: hdr, stride: st,
                        predErrors: pePtr.baseAddress!, error: errPtr.baseAddress!, divLut: divPtr.baseAddress!,
                        p0: localP0, p1: localP1, p2: localP2, p3: localP3, pred: localPred
                    )
                    defer {
                        localP0 = b.p0; localP1 = b.p1; localP2 = b.p2; localP3 = b.p3
                        localPred = b.pred
                    }
                    return try body(&b)
                }
            }
        }
    }

    /// Compute property 15 (kWPProp) — the largest absolute error
    /// among the W, N, NW, NE neighbours. Returns 0 on the very
    /// first pixel where no neighbours have errors yet.
    package func propertyValue(x: Int, y: Int, xsize: Int) -> Int32 {
        let curRowOff  = (y & 1 == 1) ? 0 : stride
        let prevRowOff = (y & 1 == 1) ? stride : 0
        let posN  = prevRowOff + x
        let posNE = (x < xsize - 1) ? posN + 1 : posN
        let posNW = (x > 0) ? posN - 1 : posN
        let teW: Int64 = (x == 0) ? 0 : error[curRowOff + x - 1]
        let teN: Int64 = error[posN]
        let teNW: Int64 = error[posNW]
        let teNE: Int64 = error[posNE]
        var p: Int64 = teW
        if abs(teN)  > abs(p) { p = teN }
        if abs(teNW) > abs(p) { p = teNW }
        if abs(teNE) > abs(p) { p = teNE }
        return Int32(truncatingIfNeeded: p)
    }

    /// Compute the weighted-predictor output at `(x, y)`. Caller
    /// supplies the unshifted neighbour pixel values; this function
    /// internally applies `AddBits` (≪ 3) and shifts back at the end.
    /// **Mutates** `prediction[]` and `pred` for the next `update`.
    package mutating func predict(
        x: Int, y: Int, xsize: Int,
        n: Int32, w: Int32, ne: Int32, nw: Int32, nn: Int32
    ) -> Int32 {
        withBuffers { $0.predict(x: x, y: y, xsize: xsize, n: n, w: w, ne: ne, nw: nw, nn: nn) }
    }

    /// Fold the actual decoded pixel value into the running per-row
    /// error arrays. **Must** be called after `predict` for every
    /// pixel in scan order — the prediction at `(x, y+1)` depends on
    /// the errors recorded at row y.
    package mutating func update(actual: Int32, x: Int, y: Int, xsize: Int) {
        withBuffers { $0.update(actual: actual, x: x, y: y, xsize: xsize) }
    }
}
