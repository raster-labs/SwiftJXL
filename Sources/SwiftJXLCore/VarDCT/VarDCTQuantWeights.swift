// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Default VarDCT quantisation weight tables per ISO/IEC 18181-1 Annex C (`DequantMatrixSet`).
package enum VarDCTQuantWeights {
    private struct DCTParamTable: Sendable {
        let bands: [[Float]]
        let distanceBands: [[Float]]
    }

    // ISO/IEC 18181-1 Annex C Table C.1 — DCT8x8 (id = 0)
    private static let dct8Bands: [[Double]] = [
        [3150.0, 1.0, 1.0 / 1.4, 1.0 / 1.4, 1.0 / 1.4, 1.0 / 3.0],
        [560.0, 1.0, 1.0 / 1.3, 1.0 / 1.3, 1.0 / 1.3, 1.0 / 1.3],
        [512.0, 1.0 / 3.0, 1.0 / 2.0, 1.0, 1.0 / 2.0, 1.0 / 3.0],
    ]

    // ISO/IEC 18181-1 Annex C Table C.5 — DCT16x16 (id = 4)
    private static let dct16Bands: [[Double]] = [
        [8996.94446, 0.43476818, 0.66923015, 0.69487914, 0.61162029, 0.52582468, 0.38223321],
        [3191.17137, 0.59737898, 0.55324505, 0.68998322, 0.73603305, 0.76149065, 0.72663232],
        [1157.49496, 0.32753478, 0.41666517, 0.66363051, 0.70072716, 0.40230459, 0.16889313],
    ]

    // ISO/IEC 18181-1 Annex C Table C.6 — DCT32x32 (id = 5)
    private static let dct32Bands: [[Double]] = [
        [15718.7825, 0.49381680, 0.50504960, 0.52598277, 0.71428580, 0.67195686, 0.70369628, 0.78740268],
        [7317.0631, 0.55341698, 0.56710428, 0.64242438, 0.66762527, 0.69589450, 0.71336748, 0.78539405],
        [3804.7369, 0.24619250, 0.32879450, 0.33073247, 0.64535372, 0.71428337, 0.71428662, 0.76923348],
    ]

    // ISO/IEC 18181-1 Annex C Table C.7 — DCT16x8 / DCT8x16 (id = 6, 7)
    private static let dct8x16Bands: [[Double]] = [
        [7240.73827, 1.0 / 1.7, 1.0 / 1.7, 1.0 / 1.2, 1.0 / 1.2, 1.0 / 1.2, 1.0 / 1.5],
        [1448.1868, 1.0 / 1.5, 1.0 / 1.5, 1.0 / 1.5, 1.0 / 1.2, 1.0 / 1.2, 1.0 / 1.2],
        [506.8565, 1.0 / 2.4, 1.0 / 1.2, 1.0 / 1.5, 1.0 / 1.5, 1.0 / 2.5, 1.0 / 4.6],
    ]

    // ISO/IEC 18181-1 Annex C Table C.8 — DCT32x8 / DCT8x32 (id = 8, 9)
    private static let dct8x32Bands: [[Double]] = [
        [16282.8001, 0.359560, 0.380093, 0.490626, 0.540540, 0.588236, 0.526316, 0.447216],
        [5089.3141, 0.757503, 0.738782, 0.767220, 0.621119, 0.666669, 0.666676, 0.624967],
        [3397.6609, 0.756851, 0.743439, 0.587064, 0.526316, 0.499999, 0.500001, 0.459675],
    ]

    // ISO/IEC 18181-1 Annex C Table C.9 — DCT32x16 / DCT16x32 (id = 10, 11)
    private static let dct16x32Bands: [[Double]] = [
        [13844.8076, 0.507328, 0.603136, 0.704096, 0.814919, 0.819267, 0.815663, 0.625002],
        [4799.0889, 0.620621, 0.544152, 0.558617, 0.787851, 0.723207, 0.813511, 0.828369],
        [1807.2365, 1.0 / 2.2, 1.0 / 2.2, 1.0 / 1.7, 1.0 / 1.7, 1.0 / 1.7, 1.0 / 1.4, 1.0 / 1.5],
    ]

    // ISO/IEC 18181-1 Annex C Table C.13 — DCT64x64 (id = 18)
    private static let dct64Bands: [[Double]] = [
        [23965.8367, 0.493835, 0.561797, 0.606017, 0.840042, 0.827682, 0.703697, 0.753388],
        [8379.8774, 0.766785, 0.733512, 0.737136, 0.743878, 0.747945, 0.768163, 0.785414],
        [4493.1646, 0.4545314, 0.4545466, 0.555555, 0.588236, 0.588235, 0.714284, 0.666670],
    ]

    // ISO/IEC 18181-1 Annex C Table C.14 — DCT64x32 / DCT32x64 (id = 19, 20)
    private static let dct32x64Bands: [[Double]] = [
        [15359.1339, 0.493819, 0.561799, 0.606016, 0.840043, 0.827682, 0.703697, 0.753390],
        [5597.4321, 0.766744, 0.733517, 0.737134, 0.743877, 0.747946, 0.768163, 0.785412],
        [2919.9871, 0.454541, 0.454546, 0.555555, 0.588236, 0.588235, 0.714285, 0.666670],
    ]

    // ISO/IEC 18181-1 Annex C Table C.2 — Hornuss (id = 1)
    private static let hornussDC: [Float] = [3160.0, 864.0, 200.0]
    private static let hornussAC: [Float] = [280.0, 60.0, 18.0]

    // ISO/IEC 18181-1 Annex C Table C.3 — DCT2x2 (id = 2)
    private static let dct2x2Bands: [[Float]] = [
        [3840.0, 2560.0, 1280.0, 640.0, 480.0, 300.0],
        [960.0, 640.0, 320.0, 180.0, 140.0, 120.0],
        [640.0, 320.0, 128.0, 64.0, 32.0, 16.0],
    ]

    // ISO/IEC 18181-1 Annex C Table C.4 — DCT4x4 (id = 3)
    private static let dct4x4Bands: [[Double]] = [
        [2200.0, 1.0, 1.0, 1.0],
        [392.0, 1.0, 1.0, 1.0],
        [112.0, 0.8, 0.8, 1.0 / 1.5],
    ]

    // ISO/IEC 18181-1 Annex C Table C.10 — DCT4x8 / DCT8x4 (id = 12, 13)
    private static let dct4x8Bands: [[Double]] = [
        [2198.06724, 0.713786, 0.713798, 0.753363, 0.753364, 0.777295, 0.777299],
        [764.36621, 0.720505, 0.720507, 0.712920, 0.712918, 0.884420, 0.884418],
        [527.10772, 0.637650, 0.637650, 0.638866, 0.638865, 0.622046, 0.622045],
    ]

    // ISO/IEC 18181-1 Annex C Table C.11 — AFV0..3 (id = 14..17)
    private static let afvDC: [Float] = [3072.0, 1024.0, 384.0]
    private static let afvWeights: [[Float]] = [
        [3072.0, 256.0, 414.0, 414.0, 256.0, 256.0, 414.0, 414.0, 414.0, 414.0, 414.0, 414.0, 414.0, 414.0, 414.0, 414.0],
        [1024.0, 50.0, 58.0, 58.0, 50.0, 50.0, 58.0, 58.0, 58.0, 58.0, 58.0, 58.0, 58.0, 58.0, 58.0, 58.0],
        [384.0, 12.0, 22.0, 17.133795, 12.0, 12.0, 17.753277, 17.066208, 21.039696, 18.488556, 15.428510, 12.966499, 19.905684, 15.129067, 14.056164, 11.264018],
    ]

    private static func buildDCTMatrix(
        _ bands: [[Double]],
        canonicalRows: Int,
        canonicalColumns: Int
    ) -> [Float] {
        let count = canonicalRows * canonicalColumns
        let maxR = Double(max(1, canonicalRows - 1))
        let maxC = Double(max(1, canonicalColumns - 1))
        let invSqrt2 = 1.0 / 2.0.squareRoot()

        var out = [Float](repeating: 0, count: 3 * count)
        for c in 0..<3 {
            let rawBands = bands[c]
            var bandTable = [Double](repeating: 0, count: rawBands.count)
            bandTable[0] = rawBands[0]
            for i in 1..<rawBands.count {
                bandTable[i] = bandTable[i - 1] * rawBands[i]
            }
            let intervals = Double(max(1, bandTable.count - 1))

            let base = c * count
            for y in 0..<canonicalRows {
                let dy = Double(y) / maxR
                for x in 0..<canonicalColumns {
                    let dx = Double(x) / maxC
                    let dist = hypot(dx, dy) * invSqrt2
                    let pos = max(0.0, min(intervals, dist * intervals))
                    let idx = min(bandTable.count - 2, Int(pos))
                    let frac = pos - Double(idx)
                    let val = bandTable[idx] * Foundation.pow(bandTable[idx + 1] / bandTable[idx], frac)
                    out[base + y * canonicalColumns + x] = Float(val)
                }
            }
        }
        return out
    }

    private static let cached0: [Float] = buildDCTMatrix(dct8Bands, canonicalRows: 8, canonicalColumns: 8)
    private static let cached1: [Float] = {
        var out = [Float](repeating: 0, count: 192)
        for c in 0..<3 {
            let base = c * 64
            for y in 0..<8 {
                for x in 0..<8 {
                    out[base + y * 8 + x] = (x < 2 && y < 2) ? hornussDC[c] : hornussAC[c]
                }
            }
        }
        return out
    }()
    private static let cached2: [Float] = {
        var out = [Float](repeating: 0, count: 192)
        for c in 0..<3 {
            let b = dct2x2Bands[c]
            let base = c * 64
            for y in 0..<8 {
                for x in 0..<8 {
                    let w: Float
                    if x < 2 && y < 2 {
                        w = (x == 1 && y == 1) ? b[1] : b[0]
                    } else if x < 4 && y < 4 {
                        w = (x >= 2 && y >= 2) ? b[3] : b[2]
                    } else if x < 4 || y < 4 {
                        w = b[4]
                    } else {
                        w = b[5]
                    }
                    out[base + y * 8 + x] = w
                }
            }
        }
        return out
    }()
    private static let cached3: [Float] = {
        let w4x4 = buildDCTMatrix(dct4x4Bands, canonicalRows: 4, canonicalColumns: 4)
        var out = [Float](repeating: 0, count: 192)
        for c in 0..<3 {
            let base = c * 64
            let base4x4 = c * 16
            for y in 0..<8 {
                for x in 0..<8 {
                    out[base + y * 8 + x] = (x < 2 && y < 2)
                        ? hornussDC[c]
                        : w4x4[base4x4 + (y / 2) * 4 + (x / 2)]
                }
            }
        }
        return out
    }()
    private static let cached4: [Float] = buildDCTMatrix(dct16Bands, canonicalRows: 16, canonicalColumns: 16)
    private static let cached5: [Float] = buildDCTMatrix(dct32Bands, canonicalRows: 32, canonicalColumns: 32)
    private static let cached6_7: [Float] = buildDCTMatrix(dct8x16Bands, canonicalRows: 8, canonicalColumns: 16)
    private static let cached8_9: [Float] = buildDCTMatrix(dct8x32Bands, canonicalRows: 8, canonicalColumns: 32)
    private static let cached10_11: [Float] = buildDCTMatrix(dct16x32Bands, canonicalRows: 16, canonicalColumns: 32)
    private static let cached12_13: [Float] = {
        let w4x8 = buildDCTMatrix(dct4x8Bands, canonicalRows: 4, canonicalColumns: 8)
        var out = [Float](repeating: 0, count: 192)
        for c in 0..<3 {
            let base = c * 64
            let base4x8 = c * 32
            for y in 0..<8 {
                for x in 0..<8 {
                    out[base + y * 8 + x] = w4x8[base4x8 + (y / 2) * 8 + x]
                }
            }
        }
        return out
    }()
    private static let cached14_17: [Float] = {
        let w4x8 = buildDCTMatrix(dct4x8Bands, canonicalRows: 4, canonicalColumns: 8)
        let w4x4 = buildDCTMatrix(dct4x4Bands, canonicalRows: 4, canonicalColumns: 4)
        var out = [Float](repeating: 0, count: 192)
        for c in 0..<3 {
            let base = c * 64
            let base4x8 = c * 32
            let base4x4 = c * 16
            for y in 0..<8 {
                for x in 0..<8 {
                    let w: Float
                    if (y == 0 && x == 1) || (y == 1 && x == 0) {
                        w = afvDC[c]
                    } else if (y & 1) == 1 {
                        w = w4x8[base4x8 + (y / 2) * 8 + x]
                    } else if (x & 1) == 1 {
                        w = w4x4[base4x4 + (y / 2) * 4 + (x / 2)]
                    } else {
                        w = afvWeights[c][(y / 2) * 4 + (x / 2)]
                    }
                    out[base + y * 8 + x] = w
                }
            }
        }
        return out
    }()
    private static let cached18: [Float] = buildDCTMatrix(dct64Bands, canonicalRows: 64, canonicalColumns: 64)
    private static let cached19_20: [Float] = buildDCTMatrix(dct32x64Bands, canonicalRows: 32, canonicalColumns: 64)

    package static func make(
        identifier: Int,
        rows: Int,
        columns: Int,
        budget: ScalarOperationBudget
    ) throws -> [Float] {
        try budget.checkpoint()
        guard (0...20).contains(identifier), rows > 0, columns > 0 else {
            throw VarDCTError.invalidTransform
        }
        let (count, over1) = rows.multipliedReportingOverflow(by: columns)
        let (total, over2) = count.multipliedReportingOverflow(by: 3)
        guard !over1, !over2 else {
            throw VarDCTError.invalidTransform
        }
        try budget.reserveWorkspace(ScalarOperationBudget.product(total, MemoryLayout<Float>.stride))

        let canonicalRows = min(rows, columns)
        let canonicalColumns = max(rows, columns)

        switch identifier {
        case 0:
            guard count == 64 else { throw VarDCTError.invalidTransform }
            return cached0
        case 1:
            guard count == 64 else { throw VarDCTError.invalidTransform }
            return cached1
        case 2:
            guard count == 64 else { throw VarDCTError.invalidTransform }
            return cached2
        case 3:
            guard count == 64 else { throw VarDCTError.invalidTransform }
            return cached3
        case 4:
            guard canonicalRows == 16 && canonicalColumns == 16 else { throw VarDCTError.invalidTransform }
            return cached4
        case 5:
            guard canonicalRows == 32 && canonicalColumns == 32 else { throw VarDCTError.invalidTransform }
            return cached5
        case 6, 7:
            guard canonicalRows == 8 && canonicalColumns == 16 else { throw VarDCTError.invalidTransform }
            return cached6_7
        case 8, 9:
            guard canonicalRows == 8 && canonicalColumns == 32 else { throw VarDCTError.invalidTransform }
            return cached8_9
        case 10, 11:
            guard canonicalRows == 16 && canonicalColumns == 32 else { throw VarDCTError.invalidTransform }
            return cached10_11
        case 12, 13:
            guard count == 64 else { throw VarDCTError.invalidTransform }
            return cached12_13
        case 14, 15, 16, 17:
            guard count == 64 else { throw VarDCTError.invalidTransform }
            return cached14_17
        case 18:
            guard canonicalRows == 64 && canonicalColumns == 64 else { throw VarDCTError.invalidTransform }
            return cached18
        case 19, 20:
            guard canonicalRows == 32 && canonicalColumns == 64 else { throw VarDCTError.invalidTransform }
            return cached19_20
        default:
            throw VarDCTError.invalidTransform
        }
    }
}
