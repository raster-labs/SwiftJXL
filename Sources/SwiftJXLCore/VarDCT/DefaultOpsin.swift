// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Default XYB opsin colour transformation per ISO/IEC 18181-1 §10.5.
package enum DefaultOpsin {
    private static let bias: Double = 0.0037930732552754493
    private static let cbrtBias: Double = cbrt(0.0037930732552754493)

    // Forward opsin absorbance matrix (linear sRGB to LMS absorbance)
    private static let fwd00: Double = 0.30
    private static let fwd01: Double = 0.622
    private static let fwd02: Double = 0.078
    private static let fwd10: Double = 0.23
    private static let fwd11: Double = 0.692
    private static let fwd12: Double = 0.078
    private static let fwd20: Double = 0.24342268924547819
    private static let fwd21: Double = 0.20476744424496821
    private static let fwd22: Double = 0.55180986650955360

    // Default inverse opsin absorbance matrix per ISO/IEC 18181-1 §10.5
    private static let inv00: Double = 11.031566901960783
    private static let inv01: Double = -9.866943921568629
    private static let inv02: Double = -0.16462299647058826
    private static let inv10: Double = -3.254147380392157
    private static let inv11: Double = 4.418770392156863
    private static let inv12: Double = -0.16462299647058826
    private static let inv20: Double = -3.6588512862745097
    private static let inv21: Double = 2.7129230470588235
    private static let inv22: Double = 1.9459282392156863

    /// Converts bounded linear sRGB `[0, 1]` samples into XYB coordinates.
    @inline(__always)
    package static func forward(_ rgb: (Double, Double, Double)) throws -> (X: Double, Y: Double, B: Double) {
        let (r, g, b) = rgb
        guard r.isFinite, g.isFinite, b.isFinite,
              r >= 0.0, r <= 1.0,
              g >= 0.0, g <= 1.0,
              b >= 0.0, b <= 1.0 else {
            throw ScalarModularError.invalidInput("Forward opsin input must be finite in [0, 1]")
        }
        let lMix = fwd00 * r + fwd01 * g + fwd02 * b + bias
        let mMix = fwd10 * r + fwd11 * g + fwd12 * b + bias
        let sMix = fwd20 * r + fwd21 * g + fwd22 * b + bias

        let lGamma = cbrt(lMix) - cbrtBias
        let mGamma = cbrt(mMix) - cbrtBias
        let sGamma = cbrt(sMix) - cbrtBias

        let x = 0.5 * (lGamma - mGamma)
        let y = 0.5 * (lGamma + mGamma)
        let bOut = sGamma
        return (X: x, Y: y, B: bOut)
    }

    /// Converts XYB coordinates into unclipped linear sRGB samples per ISO/IEC 18181-1 §10.5.
    @inline(__always)
    package static func inverse(_ xyb: (X: Double, Y: Double, B: Double)) throws -> (R: Double, G: Double, B: Double) {
        let (x, y, b) = xyb
        guard x.isFinite, y.isFinite, b.isFinite else {
            throw ScalarModularError.invalidInput("Inverse opsin input must be finite")
        }
        let lGamma = y + x + cbrtBias
        let mGamma = y - x + cbrtBias
        let sGamma = b + cbrtBias

        let l = (lGamma * lGamma * lGamma) - bias
        let m = (mGamma * mGamma * mGamma) - bias
        let s = (sGamma * sGamma * sGamma) - bias

        let rOut = inv00 * l + inv01 * m + inv02 * s
        let gOut = inv10 * l + inv11 * m + inv12 * s
        let bOut = inv20 * l + inv21 * m + inv22 * s

        guard rOut.isFinite, gOut.isFinite, bOut.isFinite else {
            throw ScalarModularError.invalidInput("Inverse opsin overflowed finite range")
        }
        return (R: rOut, G: gOut, B: bOut)
    }

    /// Unchecked inverse opsin transform for callers whose XYB inputs are already finite `Float` values.
    @inline(__always)
    package static func inverseUnchecked(_ x: Double, _ y: Double, _ b: Double) -> (R: Double, G: Double, B: Double) {
        let lGamma = y + x + cbrtBias
        let mGamma = y - x + cbrtBias
        let sGamma = b + cbrtBias

        let l = (lGamma * lGamma * lGamma) - bias
        let m = (mGamma * mGamma * mGamma) - bias
        let s = (sGamma * sGamma * sGamma) - bias

        let rOut = inv00 * l + inv01 * m + inv02 * s
        let gOut = inv10 * l + inv11 * m + inv12 * s
        let bOut = inv20 * l + inv21 * m + inv22 * s
        return (R: rOut, G: gOut, B: bOut)
    }
}
