// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift VarDCT/SmallACTransforms.swift and Codec/JXLDecoder.swift
// at 57e81cb9e2411d1efac435b429a306a031744c1e; identity formula checked against
// libjxl dec_transforms-inl.h at a7a9c787341cf703dede03c2009fa460cae5e5df.
// Copyright (c) 2026 Raster-Lab. JPEG XL Project Authors retain BSD-3-Clause.
import Foundation

package enum VarDCTSmallTransforms {
    package static func inverse(_ coefficients: [Float], identifier: Int,
                                budget: ScalarOperationBudget) throws -> [Float] {
        try budget.checkpoint()
        guard [1,2,3,12,13].contains(identifier), coefficients.count == 64 else { throw VarDCTError.invalidTransform }
        guard coefficients.allSatisfy(\.isFinite) else { throw VarDCTError.nonFiniteSample }
        try budget.reserveWorkspace(1024 * 4)
        var pixels = [Float](repeating: 0, count: 64)
        if identifier == 2 {
            pixels = coefficients
            for size in [2,4,8] {
                try budget.checkpoint()
                let source = pixels, half = size / 2
                for y in 0..<half { for x in 0..<half {
                    let a = source[y * 8 + x], b = source[y * 8 + half + x]
                    let c = source[(y + half) * 8 + x], d = source[(y + half) * 8 + half + x]
                    pixels[y * 16 + x * 2] = a + b + c + d
                    pixels[y * 16 + x * 2 + 1] = a + b - c - d
                    pixels[(y * 2 + 1) * 8 + x * 2] = a - b + c - d
                    pixels[(y * 2 + 1) * 8 + x * 2 + 1] = a - b - c + d
                } }
            }
        } else if identifier == 1 || identifier == 3 {
            let a = coefficients[0], b = coefficients[1], c = coefficients[8], d = coefficients[9]
            let dc = [a+b+c+d, a+b-c-d, a-b+c-d, a-b-c+d]
            for y in 0..<2 { for x in 0..<2 {
                try budget.checkpoint()
                if identifier == 1 {
                    var sum: Float = 0
                    for yy in 0..<4 { for xx in 0..<4 where xx != 0 || yy != 0 {
                        sum += coefficients[(y + yy * 2) * 8 + x + xx * 2]
                    } }
                    let centre = dc[y * 2 + x] - sum / 16
                    for yy in 0..<4 { for xx in 0..<4 {
                        let at = (y * 4 + yy) * 8 + x * 4 + xx
                        pixels[at] = xx == 1 && yy == 1 ? centre : coefficients[(y + yy * 2) * 8 + x + xx * 2] + centre
                    } }
                    pixels[y * 32 + x * 4] = coefficients[(y + 2) * 8 + x + 2] + centre
                } else {
                    var block = [Float](repeating: 0, count: 16)
                    block[0] = dc[y * 2 + x]
                    for yy in 0..<4 { for xx in 0..<4 where xx != 0 || yy != 0 {
                        block[xx * 4 + yy] = coefficients[(y + yy * 2) * 8 + x + xx * 2]
                    } }
                    let values = try ScaledDCT(rows: 4, columns: 4, direction: .inverse, budget: budget).apply(block)
                    for yy in 0..<4 { for xx in 0..<4 { pixels[(y * 4 + yy) * 8 + x * 4 + xx] = values[yy * 4 + xx] } }
                }
            } }
        } else {
            let dc = [coefficients[0] + coefficients[8], coefficients[0] - coefficients[8]]
            let vertical = identifier == 12, rows = vertical ? 4 : 8, columns = vertical ? 8 : 4
            for half in 0..<2 {
                var block = [Float](repeating: 0, count: 32)
                block[0] = dc[half]
                for y in 0..<4 { for x in 0..<8 where x != 0 || y != 0 {
                    block[vertical ? y * 8 + x : x * 4 + y] = coefficients[(half + y * 2) * 8 + x]
                } }
                let values = try ScaledDCT(rows: rows, columns: columns, direction: .inverse, budget: budget).apply(block)
                for y in 0..<rows { for x in 0..<columns {
                    pixels[(y + (vertical ? half * 4 : 0)) * 8 + x + (vertical ? 0 : half * 4)] = values[y * columns + x]
                } }
            }
        }
        guard pixels.allSatisfy(\.isFinite) else { throw VarDCTError.nonFiniteSample }
        try budget.checkpoint()
        return pixels
    }
}
