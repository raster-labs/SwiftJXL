// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Default tables adapted from JXLSwift VarDCT/QuantWeights.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e. Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause; see libjxl-LICENSE.txt.
import Foundation

package enum VarDCTQuantWeights {
    package static func supports(_ id: Int) -> Bool { (0...20).contains(id) }
    package static func make(identifier: Int, rows: Int, columns: Int,
                             budget: ScalarOperationBudget) throws -> [Float] {
        if [1,2,3,12,13].contains(identifier) { return try smallWeights(identifier: identifier, budget: budget) }
        if (14...17).contains(identifier) { return try afvWeights(budget: budget) }
        let bands: (x: [Float], y: [Float], b: [Float])
        switch identifier {
        case 0: bands = dct8x8
        case 4: bands = dct16x16
        case 5: bands = dct32x32
        case 6,7: bands = dct8x16
        case 8,9: bands = dct8x32
        case 10,11: bands = dct16x32
        case 18: bands = dct64x64
        case 19,20: bands = dct32x64
        default: throw VarDCTError.unsupportedStrategy(identifier)
        }
        return try radial(rows: rows, columns: columns, bands: bands, budget: budget)
    }
    private static func radial(rows: Int, columns: Int, bands: (x: [Float], y: [Float], b: [Float]),
                                budget: ScalarOperationBudget) throws -> [Float] {
        guard [4,8,16,32,64].contains(rows), [4,8,16,32,64].contains(columns) else { throw VarDCTError.invalidTransform }
        let size = rows * columns
        try budget.reserveWorkspace(size * 3 * 4 + 1024)
        var output = [Float](repeating: 0, count: size * 3)
        let all = [bands.x, bands.y, bands.b]
        for c in 0..<3 {
            let b = all[c]
            var curve = b
            for i in 1..<curve.count { curve[i] = curve[i - 1] * (b[i] > 0 ? 1 + b[i] : 1 / (1 - b[i])) }
            let scale = Float(curve.count - 1) / (sqrtf(2) + 1e-6)
            let sx = scale / Float(columns - 1), sy = scale / Float(rows - 1)
            for y in 0..<rows {
                try budget.checkpoint()
                for x in 0..<columns {
                    let dx = Float(x) * sx, dy = Float(y) * sy, distance = sqrtf(dx * dx + dy * dy)
                    let i = min(Int(distance), curve.count - 2)
                    output[c * size + y * columns + x] = curve[i] * powf(curve[i + 1] / curve[i], distance - Float(i))
                }
            }
        }
        return output
    }
    private static func smallWeights(identifier: Int, budget: ScalarOperationBudget) throws -> [Float] {
        try budget.reserveWorkspace(192 * 4)
        var output = [Float](repeating: 1, count: 192)
        if identifier == 1 || identifier == 2 {
            let bands = identifier == 1 ? identity : dct2x2
            for (c, weights) in [bands.x,bands.y,bands.b].enumerated() {
                for y in 0..<8 { for x in 0..<8 {
                    let band: Int
                    if identifier == 1 { band = (x == 1 && y == 0) || (x == 0 && y == 1) ? 1 : (x == 1 && y == 1 ? 2 : 0) }
                    else if max(x,y) < 2 { band = x == 1 && y == 1 ? 1 : 0 }
                    else if max(x,y) < 4 { band = x >= 2 && y >= 2 ? 3 : 2 }
                    else { band = x >= 4 && y >= 4 ? 5 : 4 }
                    output[c * 64 + y * 8 + x] = weights[band]
                } }
            }
        } else {
            let columns = identifier == 3 ? 4 : 8
            let sub = try radial(rows: 4, columns: columns, bands: identifier == 3 ? dct4x4 : dct4x8, budget: budget)
            for c in 0..<3 { for y in 0..<8 { for x in 0..<8 {
                output[c * 64 + y * 8 + x] = sub[c * 4 * columns + (y / 2) * columns + (columns == 4 ? x / 2 : x)]
            } } }
        }
        try budget.checkpoint()
        return output
    }
    private static func afvWeights(budget: ScalarOperationBudget) throws -> [Float] {
        let square = try radial(rows: 4, columns: 4, bands: dct4x4, budget: budget)
        let wide = try radial(rows: 4, columns: 8, bands: dct4x8, budget: budget)
        try budget.reserveWorkspace(192 * 4 + 1024)
        var output = [Float](repeating: 0, count: 192)
        let frequencies: [Float] = [0,0,0.8517778890324296,5.37778436506804,0,0,
            4.734747904497923,5.449245381693219,1.6598270267479331,4,
            7.275749096817861,10.423227632456525,2.662932286148962,
            7.630657783650829,8.962388608184032,12.97166202570235]
        let lo: Float = 0.8517778890324296, hi: Float = 12.97166202570235 - lo + 1e-6
        for (c, weights) in [afv.x,afv.y,afv.b].enumerated() {
            try budget.checkpoint()
            var curve = Array(weights[5...8])
            for i in 1..<4 { curve[i] = curve[i - 1] * (weights[i + 5] > 0 ? 1 + weights[i + 5] : 1 / (1 - weights[i + 5])) }
            let start = c * 64
            output[start] = 1
            output[start + 8] = weights[0]; output[start + 1] = weights[1]
            output[start + 16] = weights[2]; output[start + 2] = weights[3]; output[start + 18] = weights[4]
            for y in 0..<4 { for x in 0..<8 {
                if x < 4, !(x < 2 && y < 2) {
                    let distance = (frequencies[y * 4 + x] - lo) * 3 / hi, i = min(Int(distance), 2)
                    output[start + y * 16 + x * 2] = curve[i] * powf(curve[i + 1] / curve[i], distance - Float(i))
                }
                if x != 0 || y != 0 {
                    output[start + (y * 2 + 1) * 8 + x] = wide[c * 32 + y * 8 + x]
                    if x < 4 { output[start + y * 16 + x * 2 + 1] = square[c * 16 + y * 4 + x] }
                }
            } }
        }
        return output
    }
    private static let dct8x8: (x: [Float], y: [Float], b: [Float]) = (
        x: [3150.0,    0.0, -0.4, -0.4, -0.4, -2.0],
        y: [ 560.0,    0.0, -0.3, -0.3, -0.3, -0.3],
        b: [ 512.0,   -2.0, -1.0,  0.0, -1.0, -2.0]
    )

    private static let dct16x16: (x: [Float], y: [Float], b: [Float]) = (
        x: [
             8996.8725711814115328,
               -1.3000777393353804,
               -0.49424529824571225,
               -0.439093774457103443,
               -0.6350101832695744,
               -0.90177264050827612,
               -1.6162099239887414,
        ],
        y: [
             3191.48366296844234752,
               -0.67424582104194355,
               -0.80745813428471001,
               -0.44925837484843441,
               -0.35865440981033403,
               -0.31322389111877305,
               -0.37615025315725483,
        ],
        b: [
             1157.50408145487200256,
               -2.0531423165804414,
               -1.4,
               -0.50687130033378396,
               -0.42708730624733904,
               -1.4856834539296244,
               -4.9209142884401604,
        ]
    )

    private static let dct32x32: (x: [Float], y: [Float], b: [Float]) = (
        x: [
             15718.40830982518931456,
                -1.025,
                -0.98,
                -0.9012,
                -0.4,
                -0.48819395464,
                -0.421064,
                -0.27,
        ],
        y: [
              7305.7636810695983104,
                -0.8041958212306401,
                -0.7633036457487539,
                -0.55660379990111464,
                -0.49785304658857626,
                -0.43699592683512467,
                -0.40180866526242109,
                -0.27321683125358037,
        ],
        b: [
              3803.53173721215041536,
                -3.060733579805728,
                -2.0413270132490346,
                -2.0235650159727417,
                -0.5495389509954993,
                -0.4,
                -0.4,
                -0.3,
        ]
    )

    private static let dct8x16: (x: [Float], y: [Float], b: [Float]) = (
        x: [7240.7734393502, -0.7, -0.7, -0.2, -0.2, -0.2, -0.5],
        y: [1448.15468787004, -0.5, -0.5, -0.5, -0.2, -0.2, -0.2],
        b: [ 506.854140754517, -1.4, -0.2, -0.5, -0.5, -1.5, -3.6]
    )

    private static let dct8x32: (x: [Float], y: [Float], b: [Float]) = (
        x: [
            16283.2494710648897,
               -1.7812845336559429,
               -1.6309059012653515,
               -1.0382179034313539,
               -0.85,
               -0.7,
               -0.9,
               -1.2360638576849587,
        ],
        y: [
             5089.15750884921511936,
               -0.320049391452786891,
               -0.35362849922161446,
               -0.30340000000000003,
               -0.61,
               -0.5,
               -0.5,
               -0.6,
        ],
        b: [
             3397.77603275308720128,
               -0.321327362693153371,
               -0.34507619223117997,
               -0.70340000000000003,
               -0.9,
               -1.0,
               -1.0,
               -1.1754605576265209,
        ]
    )

    private static let dct32x64: (x: [Float], y: [Float], b: [Float]) = (
        x: [
             Float(0.65 * 23629.073922049845),
                -1.025,
                -0.78,
                -0.65012,
                -0.19041574084286472,
                -0.20819395464,
                -0.421064,
                -0.32733845535848671,
        ],
        y: [
             Float(0.65 * 8611.3238710010046),
                -0.3041958212306401,
                -0.3633036457487539,
                -0.35660379990111464,
                -0.3443074455424403,
                -0.33699592683512467,
                -0.30180866526242109,
                -0.27321683125358037,
        ],
        b: [
             Float(0.65 * 4492.2486445538634),
                -1.2,
                -1.2,
                -0.8,
                -0.7,
                -0.7,
                -0.4,
                -0.5,
        ]
    )

    private static let dct64x64: (x: [Float], y: [Float], b: [Float]) = (
        x: [
             Float(0.9 * 26629.073922049845),
                -1.025,
                -0.78,
                -0.65012,
                -0.19041574084286472,
                -0.20819395464,
                -0.421064,
                -0.32733845535848671,
        ],
        y: [
             Float(0.9 * 9311.3238710010046),
                -0.3041958212306401,
                -0.3633036457487539,
                -0.35660379990111464,
                -0.3443074455424403,
                -0.33699592683512467,
                -0.30180866526242109,
                -0.27321683125358037,
        ],
        b: [
             Float(0.9 * 4992.2486445538634),
                -1.2,
                -1.2,
                -0.8,
                -0.7,
                -0.7,
                -0.4,
                -0.5,
        ]
    )

    private static let dct16x32: (x: [Float], y: [Float], b: [Float]) = (
        x: [
             13844.97076442300573,
                -0.97113799999999995,
                -0.658,
                -0.42026,
                -0.22712,
                -0.2206,
                -0.226,
                -0.6,
        ],
        y: [
              4798.964084220744293,
                -0.61125308982767057,
                -0.83770786552491361,
                -0.79014862079498627,
                -0.2692727459704829,
                -0.38272769465388551,
                -0.22924222653091453,
                -0.20719098826199578,
        ],
        b: [
              1807.236946760964614,
                -1.2,
                -1.2,
                -0.7,
                -0.7,
                -0.7,
                -0.4,
                -0.5,
        ]
    )
    private static let dct4x4: (x: [Float], y: [Float], b: [Float]) = (
        x: [2200.0, 0.0, 0.0, 0.0],
        y: [ 392.0, 0.0, 0.0, 0.0],
        b: [ 112.0, -0.25, -0.25, -0.5]
    )
    private static let dct4x8: (x: [Float], y: [Float], b: [Float]) = (
        x: [2198.050556016380522,  -0.96269623020744692,
            -0.76194253026666783,  -0.6551140670773547],
        y: [ 764.3655248643528689, -0.92630200888366945,
            -0.9675229603596517,   -0.27845290869168118],
        b: [ 527.107573587542228,  -1.4594385811273854,
            -1.450082094097871593, -1.5843722511996204]
    )
    private static let afv: (x: [Float], y: [Float], b: [Float]) = (
        x: [3072, 3072, 256, 256, 256, 414, 0, 0, 0],
        y: [1024, 1024,  50,  50,  50,  58, 0, 0, 0],
        b: [ 384,  384,  12,  12,  12,  22, -0.25, -0.25, -0.25]
    )
    private static let identity: (x: [Float], y: [Float], b: [Float]) = (
        x: [280.0, 3160.0, 3160.0],
        y: [ 60.0,  864.0,  864.0],
        b: [ 18.0,  200.0,  200.0]
    )
    private static let dct2x2: (x: [Float], y: [Float], b: [Float]) = (
        x: [3840.0, 2560.0, 1280.0, 640.0, 480.0, 300.0],
        y: [ 960.0,  640.0,  320.0, 180.0, 140.0, 120.0],
        b: [ 640.0,  320.0,  128.0,  64.0,  32.0,  16.0]
    )
}
