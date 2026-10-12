// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift VarDCT/OpsinXYB.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// ISO/IEC 18181-1 §C.5.4. JPEG XL Project Authors' default opsin constants.
// See Documentation/ThirdParty/libjxl-LICENSE.txt.
import Foundation

/// Default-matrix, default-intensity XYB conversion only. Custom profiles and
/// intensity targets must be handled explicitly by the eventual frame caller.
/// Double intermediates avoid avoidable cancellation in the inverse matrix.
package enum DefaultOpsin {

    // 3×3 opsin absorbance matrix from libjxl
    // `cms/opsin_params.h::kOpsinAbsorbanceMatrix`. Acts on a
    // linear-RGB column vector and yields LMS-cone-style absorbance.
    private static let M00: Double = 0.30
    private static let M02: Double = 0.078
    private static let M01: Double = 1.0 - M02 - M00      // = 0.622

    private static let M12: Double = 0.078
    private static let M10: Double = 0.23
    private static let M11: Double = 1.0 - M12 - M10      // = 0.692

    private static let M20: Double = 0.24342268924547819
    private static let M21: Double = 0.20476744424496821
    private static let M22: Double = 1.0 - M20 - M21      // ≈ 0.55180987

    /// Pre-computed inverse matrix (libjxl
    /// `kDefaultInverseOpsinAbsorbanceMatrix`).
    private static let invM00: Double =  11.031566901960783
    private static let invM01: Double =  -9.866943921568629
    private static let invM02: Double =  -0.16462299647058826
    private static let invM10: Double =  -3.254147380392157
    private static let invM11: Double =   4.418770392156863
    private static let invM12: Double =  -0.16462299647058826
    private static let invM20: Double =  -3.6588512862745097
    private static let invM21: Double =   2.7129230470588235
    private static let invM22: Double =   1.9459282392156863

    /// Bias added to absorbance before the cube root, then
    /// subtracted after. Same value for all three channels.
    package static let opsinBias: Double = 0.0037930732552754493
    /// `cbrt(opsinBias)` — pre-subtracted on the forward path.
    package static let cbrtOpsinBias: Double =
        0.155954200549248618403228789114857601840543746948242  // ≈ ∛0.003793

    /// Forward: linear-RGB sample triple → XYB triple.
    /// Both vectors are length-3.
    @inline(__always)
    package static func forward(
        _ rgb: (Double, Double, Double)
    ) throws -> (X: Double, Y: Double, B: Double) {
        guard rgb.0.isFinite, rgb.1.isFinite, rgb.2.isFinite else { throw VarDCTError.nonFiniteSample }
        guard (0...1).contains(rgb.0), (0...1).contains(rgb.1), (0...1).contains(rgb.2) else {
            throw VarDCTError.invalidTransform
        }
        let r = rgb.0, g = rgb.1, b = rgb.2
        // 1. Linear → opsin absorbance (matrix multiply + bias).
        let l = M00 * r + M01 * g + M02 * b + opsinBias
        let m = M10 * r + M11 * g + M12 * b + opsinBias
        let s = M20 * r + M21 * g + M22 * b + opsinBias
        // 2. Cube root, then subtract `cbrt(opsinBias)` to recentre.
        let lr = cbrt(l) - cbrtOpsinBias
        let mr = cbrt(m) - cbrtOpsinBias
        let sr = cbrt(s) - cbrtOpsinBias
        // 3. Recombine into the XYB opponent basis (libjxl
        // `cms/jxl_cms.cc::OpsinAbsorbance` lines 100-110):
        //    X = (lr - mr) / 2;  Y = (lr + mr) / 2;  B = sr.
        return (X: 0.5 * (lr - mr),
                Y: 0.5 * (lr + mr),
                B: sr)
    }

    /// Inverse: XYB triple → linear-RGB triple.
    @inline(__always)
    package static func inverse(
        _ xyb: (X: Double, Y: Double, B: Double)
    ) throws -> (R: Double, G: Double, B: Double) {
        guard xyb.X.isFinite, xyb.Y.isFinite, xyb.B.isFinite else { throw VarDCTError.nonFiniteSample }
        // 1. Recover the cube-rooted absorbances.
        let lr = xyb.Y + xyb.X
        let mr = xyb.Y - xyb.X
        let sr = xyb.B
        // 2. Add the bias back, undo the cube root.
        let l = (lr + cbrtOpsinBias) * (lr + cbrtOpsinBias) * (lr + cbrtOpsinBias) - opsinBias
        let m = (mr + cbrtOpsinBias) * (mr + cbrtOpsinBias) * (mr + cbrtOpsinBias) - opsinBias
        let s = (sr + cbrtOpsinBias) * (sr + cbrtOpsinBias) * (sr + cbrtOpsinBias) - opsinBias
        // 3. Inverse opsin absorbance matrix.
        let r = invM00 * l + invM01 * m + invM02 * s
        let g = invM10 * l + invM11 * m + invM12 * s
        let b = invM20 * l + invM21 * m + invM22 * s
        guard r.isFinite, g.isFinite, b.isFinite else { throw VarDCTError.nonFiniteSample }
        return (R: r, G: g, B: b)
    }
}
