// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster Images Private Limited
//
// ISO/IEC 18181-1 Clause 8.3 / Table 36 (Modular predictors 0..13).
//
// Evaluates the 14 normative Modular predictors for raw predictor IDs 0..13:
//
//   0  Zero       0
//   1  Left       W
//   2  Top        N
//   3  Average0   (W + N) >> 1
//   4  Select     |W - NW| < |N - NW| ? N : W
//   5  Gradient   clamp(W + N - NW, min(W, N), max(W, N))
//   6  Weighted   wpResult                  (caller-supplied)
//   7  TopRight   NE                       (with edge fall-back to N)
//   8  TopLeft    NW
//   9  LeftLeft   WW                       (with edge fall-back to W)
//   10 Average1   (W + NW) >> 1
//   11 Average2   (NW + N) >> 1
//   12 Average3   (N + NE) >> 1
//   13 Average4   (W + N + NE + NW) >> 2

import Foundation

/// Evaluates an ISO/IEC 18181-1 Table 36 Modular predictor (`0...13`) for the given neighbourhood.
package func applyLibjxlPredictor(
    raw: UInt32, neighbourhood nbh: Neighbourhood, wpResult: Int32 = 0
) -> Int32 {
    switch raw {
    case 0:
        return 0
    case 1:
        return nbh.w
    case 2:
        return nbh.n
    case 3:
        // ISO/IEC 18181-1 Table 36: arithmetic shift (W + N) >> 1.
        return (nbh.w &+ nbh.n) &>> 1
    case 4:
        // Select: |W-NW| < |N-NW| ? N : W
        // Transformed planes can hold any signed Int32 before final sample
        // validation. Unsigned magnitude also represents abs(Int32.min).
        let pa = (nbh.w &- nbh.nw).magnitude
        let pb = (nbh.n &- nbh.nw).magnitude
        return pa < pb ? nbh.n : nbh.w
    case 5:
        // ClampedGradient.
        let g = nbh.w &+ nbh.n &- nbh.nw
        let mn = min(nbh.w, nbh.n)
        let mx = max(nbh.w, nbh.n)
        return min(max(g, mn), mx)
    case 6:
        return wpResult
    case 7:
        return nbh.ne
    case 8:
        return nbh.nw
    case 9:
        return nbh.ww
    case 10:
        return (nbh.w &+ nbh.nw) &>> 1
    case 11:
        return (nbh.nw &+ nbh.n) &>> 1
    case 12:
        return (nbh.n &+ nbh.ne) &>> 1
    case 13:
        return (nbh.w &+ nbh.n &+ nbh.ne &+ nbh.nw) &>> 2
    default:
        // Out-of-range — caller should reject before reaching here;
        // return 0 as a safe default.
        return 0
    }
}
