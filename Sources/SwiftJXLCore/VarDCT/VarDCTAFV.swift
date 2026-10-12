// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift VarDCT/AFV.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e. Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause; see libjxl-LICENSE.txt.
import Foundation

package enum VarDCTAFV {
    package static func inverse(_ coefficients: [Float], kind: Int,
                                budget: ScalarOperationBudget) throws -> [Float] {
        try budget.checkpoint()
        guard (0..<4).contains(kind), coefficients.count == 64 else { throw VarDCTError.invalidTransform }
        guard coefficients.allSatisfy(\.isFinite) else { throw VarDCTError.nonFiniteSample }
        try budget.reserveWorkspace(192 * 4)
        let ax = kind & 1, ay = kind / 2
        let dc0 = (coefficients[0] + coefficients[8] + coefficients[1]) * 4
        let dc1 = coefficients[0] + coefficients[8] - coefficients[1]
        let dc2 = coefficients[0] - coefficients[8]
        var afv = [Float](repeating: 0, count: 16), square = afv
        var rectangle = [Float](repeating: 0, count: 32)
        var pixels = [Float](repeating: 0, count: 64)
        afv[0] = dc0; square[0] = dc1; rectangle[0] = dc2
        for y in 0..<4 { for x in 0..<4 where x != 0 || y != 0 {
            afv[y * 4 + x] = coefficients[y * 16 + x * 2]
            // Square coefficient layout is transposed in the codestream.
            square[x * 4 + y] = coefficients[y * 16 + x * 2 + 1]
        } }
        for y in 0..<4 { for x in 0..<8 where x != 0 || y != 0 {
            rectangle[y * 8 + x] = coefficients[(y * 2 + 1) * 8 + x]
        } }
        for i in 0..<16 {
            try budget.checkpoint()
            var sum: Double = 0
            for j in 0..<16 { sum += Double(afv[j]) * Double(basis[j][i]) }
            let value = Float(sum)
            guard value.isFinite else { throw VarDCTError.nonFiniteSample }
            let y = ay == 1 ? 3 - i / 4 : i / 4, x = ax == 1 ? 3 - i % 4 : i % 4
            pixels[(y + ay * 4) * 8 + x + ax * 4] = value
        }
        let small = try ScaledDCT(rows: 4, columns: 4, direction: .inverse, budget: budget).apply(square)
        let wide = try ScaledDCT(rows: 4, columns: 8, direction: .inverse, budget: budget).apply(rectangle)
        for y in 0..<4 { for x in 0..<8 {
            if x < 4 { pixels[(y + ay * 4) * 8 + (1 - ax) * 4 + x] = small[y * 4 + x] }
            pixels[(y + (1 - ay) * 4) * 8 + x] = wide[y * 8 + x]
        } }
        try budget.checkpoint()
        return pixels
    }
    /// Forward orthonormal 4×4 AFV corner; the frame packing is handled by
    /// VarDCTSmallAnalysis. Reuses the same specification basis as synthesis.
    static func forwardBasis(_ pixels: [Float], budget: ScalarOperationBudget) throws -> [Float] {
        try budget.checkpoint()
        guard pixels.count == 16 else { throw VarDCTError.invalidTransform }
        guard pixels.allSatisfy(\.isFinite) else { throw VarDCTError.nonFiniteSample }
        try budget.reserveWorkspace(16 * MemoryLayout<Float>.stride)
        var output = [Float](repeating: 0, count: 16)
        for k in 0..<16 {
            var sum: Double = 0
            for i in 0..<16 { sum += Double(pixels[i]) * Double(basis[k][i]) }
            let value = Float(sum)
            guard value.isFinite else { throw VarDCTError.nonFiniteSample }
            output[k] = value
        }
        try budget.checkpoint()
        return output
    }
    private static let basis: [[Float]] = [
        // Row 0: DC (constant = 1/4).
        [0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25,
         0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25],
        // Row 1.
        [0.876902929799142, 0.2206518106944235, -0.10140050393753763,
         -0.1014005039375375, 0.2206518106944236, -0.10140050393753777,
         -0.10140050393753772, -0.10140050393753763, -0.10140050393753758,
         -0.10140050393753769, -0.1014005039375375, -0.10140050393753768,
         -0.10140050393753768, -0.10140050393753759, -0.10140050393753763,
         -0.10140050393753741],
        // Row 2.
        [0.0, 0.0, 0.40670075830260755, 0.44444816619734445,
         0.0, 0.0, 0.19574399372042936, 0.2929100136981264,
         -0.40670075830260716, -0.19574399372042872, 0.0,
         0.11379074460448091, -0.44444816619734384, -0.29291001369812636,
         -0.1137907446044814, 0.0],
        // Row 3.
        [0.0, 0.0, -0.21255748058288748, 0.3085497062849767,
         0.0, 0.4706702258572536, -0.1621205195722993, 0.0,
         -0.21255748058287047, -0.16212051957228327, -0.47067022585725277,
         -0.1464291867126764, 0.3085497062849487, 0.0,
         -0.14642918671266536, 0.4251149611657548],
        // Row 4.
        [0.0, -0.7071067811865474, 0.0, 0.0, 0.7071067811865476,
         0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        // Row 5.
        [-0.4105377591765233, 0.6235485373547691, -0.06435071657946274,
         -0.06435071657946266, 0.6235485373547694, -0.06435071657946284,
         -0.0643507165794628, -0.06435071657946274, -0.06435071657946272,
         -0.06435071657946279, -0.06435071657946266, -0.06435071657946277,
         -0.06435071657946277, -0.06435071657946273, -0.06435071657946274,
         -0.0643507165794626],
        // Row 6.
        [0.0, 0.0, -0.4517556589999482, 0.15854503551840063, 0.0,
         -0.04038515160822202, 0.0074182263792423875, 0.39351034269210167,
         -0.45175565899994635, 0.007418226379244351, 0.1107416575309343,
         0.08298163094882051, 0.15854503551839705, 0.3935103426921022,
         0.0829816309488214, -0.45175565899994796],
        // Row 7.
        [0.0, 0.0, -0.304684750724869, 0.5112616136591823, 0.0, 0.0,
         -0.290480129728998, -0.06578701549142804, 0.304684750724884,
         0.2904801297290076, 0.0, -0.23889773523344604,
         -0.5112616136592012, 0.06578701549142545, 0.23889773523345467,
         0.0],
        // Row 8.
        [0.0, 0.0, 0.3017929516615495, 0.25792362796341184, 0.0,
         0.16272340142866204, 0.09520022653475037, 0.0, 0.3017929516615503,
         0.09520022653475055, -0.16272340142866173, -0.35312385449816297,
         0.25792362796341295, 0.0, -0.3531238544981624, -0.6035859033230976],
        // Row 9.
        [0.0, 0.0, 0.40824829046386274, 0.0, 0.0, 0.0, 0.0,
         -0.4082482904638628, -0.4082482904638635, 0.0, 0.0,
         -0.40824829046386296, 0.0, 0.4082482904638634, 0.408248290463863,
         0.0],
        // Row 10.
        [0.0, 0.0, 0.1747866975480809, 0.0812611176717539, 0.0, 0.0,
         -0.3675398009862027, -0.307882213957909, -0.17478669754808135,
         0.3675398009862011, 0.0, 0.4826689115059883, -0.08126111767175039,
         0.30788221395790305, -0.48266891150598584, 0.0],
        // Row 11.
        [0.0, 0.0, -0.21105601049335784, 0.18567180916109802, 0.0, 0.0,
         0.49215859013738733, -0.38525013709251915, 0.21105601049335806,
         -0.49215859013738905, 0.0, 0.17419412659916217,
         -0.18567180916109904, 0.3852501370925211, -0.1741941265991621,
         0.0],
        // Row 12.
        [0.0, 0.0, -0.14266084808807264, -0.3416446842253372, 0.0,
         0.7367497537172237, 0.24627107722075148, -0.08574019035519306,
         -0.14266084808807344, 0.24627107722075137, 0.14883399227113567,
         -0.04768680350229251, -0.3416446842253373, -0.08574019035519267,
         -0.047686803502292804, -0.14266084808807242],
        // Row 13.
        [0.0, 0.0, -0.13813540350758585, 0.3302282550303788, 0.0,
         0.08755115000587084, -0.07946706605909573, -0.4613374887461511,
         -0.13813540350758294, -0.07946706605910261, 0.49724647109535086,
         0.12538059448563663, 0.3302282550303805, -0.4613374887461554,
         0.12538059448564315, -0.13813540350758452],
        // Row 14.
        [0.0, 0.0, -0.17437602599651067, 0.0702790691196284, 0.0,
         -0.2921026642334881, 0.3623817333531167, 0.0,
         -0.1743760259965108, 0.36238173335311646, 0.29210266423348785,
         -0.4326608024727445, 0.07027906911962818, 0.0,
         -0.4326608024727457, 0.34875205199302267],
        // Row 15.
        [0.0, 0.0, 0.11354987314994337, -0.07417504595810355, 0.0,
         0.19402893032594343, -0.435190496523228, 0.21918684838857466,
         0.11354987314994257, -0.4351904965232251, 0.5550443808910661,
         -0.25468277124066463, -0.07417504595810233, 0.2191868483885728,
         -0.25468277124066413, 0.1135498731499429],
    ]

}
