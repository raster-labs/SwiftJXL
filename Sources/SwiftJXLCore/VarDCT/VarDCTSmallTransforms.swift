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

    package static func inverse(_ coefficients: UnsafeBufferPointer<Float>, identifier: Int,
                                into pixels: UnsafeMutableBufferPointer<Float>,
                                dct4x4: ScaledDCT, dct4x8: ScaledDCT, dct8x4: ScaledDCT,
                                scratch: inout ScaledDCT.Workspace,
                                budget: ScalarOperationBudget) throws {
        try budget.checkpoint()
        guard [1,2,3,12,13].contains(identifier), coefficients.count == 64, pixels.count >= 64,
              let cPtr = coefficients.baseAddress, let pPtr = pixels.baseAddress else {
            throw VarDCTError.invalidTransform
        }
        for i in 0..<64 {
            if !cPtr[i].isFinite { throw VarDCTError.nonFiniteSample }
        }
        try budget.reserveWorkspace(1024 * 4)
        for i in 0..<64 { pPtr[i] = 0 }
        if identifier == 2 {
            for i in 0..<64 { pPtr[i] = cPtr[i] }
            try withUnsafeTemporaryAllocation(of: Float.self, capacity: 64) { sourceBuf in
                let sPtr = sourceBuf.baseAddress!
                for size in [2,4,8] {
                    try budget.checkpoint()
                    for i in 0..<64 { sPtr[i] = pPtr[i] }
                    let half = size &>> 1
                    for y in 0..<half { for x in 0..<half {
                        let a = sPtr[y &* 8 &+ x], b = sPtr[y &* 8 &+ half &+ x]
                        let c = sPtr[(y &+ half) &* 8 &+ x], d = sPtr[(y &+ half) &* 8 &+ half &+ x]
                        pPtr[y &* 16 &+ x &* 2] = a + b + c + d
                        pPtr[y &* 16 &+ x &* 2 &+ 1] = a + b - c - d
                        pPtr[(y &* 2 &+ 1) &* 8 &+ x &* 2] = a - b + c - d
                        pPtr[(y &* 2 &+ 1) &* 8 &+ x &* 2 &+ 1] = a - b - c + d
                    } }
                }
            }
        } else if identifier == 1 || identifier == 3 {
            let a = cPtr[0], b = cPtr[1], c = cPtr[8], d = cPtr[9]
            let dc = (a+b+c+d, a+b-c-d, a-b+c-d, a-b-c+d)
            try withUnsafeTemporaryAllocation(of: Float.self, capacity: 16) { blockBuf in
                let bPtr = blockBuf.baseAddress!
                for y in 0..<2 { for x in 0..<2 {
                    try budget.checkpoint()
                    let dcVal: Float
                    switch y &* 2 &+ x {
                    case 0: dcVal = dc.0
                    case 1: dcVal = dc.1
                    case 2: dcVal = dc.2
                    default: dcVal = dc.3
                    }
                    if identifier == 1 {
                        var sum: Float = 0
                        for yy in 0..<4 { for xx in 0..<4 where xx != 0 || yy != 0 {
                            sum += cPtr[(y &+ yy &* 2) &* 8 &+ x &+ xx &* 2]
                        } }
                        let centre = dcVal - sum / 16
                        for yy in 0..<4 { for xx in 0..<4 {
                            let at = (y &* 4 &+ yy) &* 8 &+ x &* 4 &+ xx
                            pPtr[at] = xx == 1 && yy == 1 ? centre : cPtr[(y &+ yy &* 2) &* 8 &+ x &+ xx &* 2] + centre
                        } }
                        pPtr[y &* 32 &+ x &* 4] = cPtr[(y &+ 2) &* 8 &+ x &+ 2] + centre
                    } else {
                        for i in 0..<16 { bPtr[i] = 0 }
                        bPtr[0] = dcVal
                        for yy in 0..<4 { for xx in 0..<4 where xx != 0 || yy != 0 {
                            bPtr[xx &* 4 &+ yy] = cPtr[(y &+ yy &* 2) &* 8 &+ x &+ xx &* 2]
                        } }
                        try budget.reserveWorkspace(384)
                        try dct4x4.apply(UnsafeBufferPointer(blockBuf), workspace: &scratch)
                        scratch.withValues { values in
                            let vPtr = values.baseAddress!
                            for yy in 0..<4 { for xx in 0..<4 {
                                pPtr[(y &* 4 &+ yy) &* 8 &+ x &* 4 &+ xx] = vPtr[yy &* 4 &+ xx]
                            } }
                        }
                    }
                } }
            }
        } else {
            let dc0 = cPtr[0] + cPtr[8], dc1 = cPtr[0] - cPtr[8]
            let vertical = identifier == 12, rows = vertical ? 4 : 8, columns = vertical ? 8 : 4
            let plan = vertical ? dct4x8 : dct8x4
            try withUnsafeTemporaryAllocation(of: Float.self, capacity: 32) { blockBuf in
                let bPtr = blockBuf.baseAddress!
                for half in 0..<2 {
                    for i in 0..<32 { bPtr[i] = 0 }
                    bPtr[0] = half == 0 ? dc0 : dc1
                    for y in 0..<4 { for x in 0..<8 where x != 0 || y != 0 {
                        bPtr[vertical ? y &* 8 &+ x : x &* 4 &+ y] = cPtr[(half &+ y &* 2) &* 8 &+ x]
                    } }
                    try budget.reserveWorkspace(896)
                    try plan.apply(UnsafeBufferPointer(blockBuf), workspace: &scratch)
                    scratch.withValues { values in
                        let vPtr = values.baseAddress!
                        for y in 0..<rows { for x in 0..<columns {
                            pPtr[(y &+ (vertical ? half &* 4 : 0)) &* 8 &+ x &+ (vertical ? 0 : half &* 4)] = vPtr[y &* columns &+ x]
                        } }
                    }
                }
            }
        }
        for i in 0..<64 {
            if !pPtr[i].isFinite { throw VarDCTError.nonFiniteSample }
        }
        try budget.checkpoint()
    }
}
