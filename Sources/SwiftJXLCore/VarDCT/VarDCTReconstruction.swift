// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift VarDCT/{QuantWeights,AdjustQuantBias,AdaptiveDCSmoothing}.swift
// and Codec/JXLDecoder.swift at 57e81cb9e2411d1efac435b429a306a031744c1e.
// Copyright (c) 2026 Raster-Lab. JPEG XL Project Authors retain BSD-3-Clause.
import Foundation

/// DCT default-matrix reconstruction into admitted algorithm planes, not a
/// final image or public capability. No successful pixels are published here.
package enum VarDCTReconstruction {
    package static func xyb(_ coefficients: VarDCTCoefficients,
                            numericalMode: VarDCTNumericalMode = .scalarNearest) throws -> [[Float]] {
        let e = coefficients.envelope, budget = e.budget
        if let unsupported = coefficients.strategies.transforms.first(where: { !VarDCTQuantWeights.supports($0.identifier) }) {
            throw VarDCTError.unsupportedStrategy(unsupported.identifier)
        }
        guard !e.frame.loopFilter.hasCustomParameters else {
            throw ScalarModularError.unsupportedProfile
        }
        let bx = coefficients.blocksX, by = coefficients.blocksY, blocks = bx * by
        let width = bx * 8, height = by * 8, samples = width * height
        try budget.reserveWorkspace(ScalarOperationBudget.product(samples + blocks * 2, 3 * 4))
        let invGlobal = Float(65536) / Float(coefficients.globalScale)
        let factors: [Float] = [4096, 512, 256].map { invGlobal / Float(coefficients.quantDC) / $0 }
        let extra = 1 / Float(1 << coefficients.dcExtraPrecision)
        let dcX = coefficients.baseX + Float(coefficients.dcX) / Float(coefficients.colourFactor)
        let dcB = coefficients.baseB + Float(coefficients.dcB) / Float(coefficients.colourFactor)
        var dc = (0..<3).map { _ in [Float](repeating: 0, count: blocks) }
        for i in 0..<blocks {
            if i & 255 == 0 { try budget.checkpoint() }
            let y = Float(coefficients.dc[1][i]) * factors[1] * extra
            dc[0][i] = Float(coefficients.dc[0][i]) * factors[0] * extra + dcX * y
            dc[1][i] = y
            dc[2][i] = Float(coefficients.dc[2][i]) * factors[2] * extra + dcB * y
        }
        if e.frame.flags & 128 == 0 { try smoothDC(&dc, width: bx, height: by, factors: factors, budget: budget) }
        try budget.reserveWorkspace(4096) // bounded small vectors
        let dm: [Float] = [powf(0.8, Float(e.frame.xQmScale) - 2), 1, powf(0.8, Float(e.frame.bQmScale) - 2)]
        var planes = (0..<3).map { _ in [Float](repeating: 0, count: samples) }
        let tilesX = (bx + 7) / 8
        // Strategy identifiers have fixed geometry in the validated map. Keep
        // at most 21 immutable tables/plans per operation; never retain them
        // globally or recompute their pow/cos tables for each image block.
        try budget.reserveWorkspace(21 * (MemoryLayout<[Float]?>.stride + MemoryLayout<ScaledDCT?>.stride))
        var weightTables = [[Float]?](repeating: nil, count: 21)
        var transforms = [ScaledDCT?](repeating: nil, count: 21)
        var axes = ScaledDCT.AxisBank(direction: .inverse, budget: budget)
        var largestTransform = 64
        var hasSmallOrAFV = false
        for (index, strategy) in coefficients.strategies.transforms.enumerated() {
            if index & 255 == 0 { try budget.checkpoint() }
            largestTransform = max(largestTransform, strategy.coveredCells * 64)
            let id = strategy.identifier
            if (1...3).contains(id) || (12...17).contains(id) { hasSmallOrAFV = true }
        }
        var scratch = try ScaledDCT.Workspace(capacity: largestTransform, budget: budget)
        let dct4x4 = try hasSmallOrAFV ? ScaledDCT(rows: 4, columns: 4, direction: .inverse, budget: budget, axes: &axes) : nil
        let dct4x8 = try hasSmallOrAFV ? ScaledDCT(rows: 4, columns: 8, direction: .inverse, budget: budget, axes: &axes) : nil
        let dct8x4 = try hasSmallOrAFV ? ScaledDCT(rows: 8, columns: 4, direction: .inverse, budget: budget, axes: &axes) : nil
        var block0 = [Float](repeating: 0, count: largestTransform)
        var block1 = [Float](repeating: 0, count: largestTransform)
        var block2 = [Float](repeating: 0, count: largestTransform)
        var smallPixels = [Float](repeating: 0, count: 64)
        let dm0 = dm[0], dm2 = dm[2]
        for strategy in coefficients.strategies.transforms {
            try budget.checkpoint()
            let x = strategy.x, y = strategy.y, tile = (y / 8) * tilesX + x / 8
            let rows = strategy.cellsY * 8, columns = strategy.cellsX * 8, size = rows * columns
            let codedRows = min(rows, columns), codedColumns = max(rows, columns)
            let identifier = strategy.identifier
            let isAFV = (14...17).contains(identifier)
            let isSmall = identifier == 1 || identifier == 2 || identifier == 3 || identifier == 12 || identifier == 13
            let transpose = !isAFV && !isSmall && rows >= columns
            if weightTables[identifier] == nil {
                weightTables[identifier] = try VarDCTQuantWeights.make(identifier: identifier,
                    rows: codedRows, columns: codedColumns, budget: budget)
            }
            guard let weights = weightTables[identifier] else { throw VarDCTError.invalidTransform }
            if !isAFV && !isSmall && transforms[identifier] == nil {
                transforms[identifier] = try ScaledDCT(rows: rows, columns: columns, direction: .inverse, budget: budget, axes: &axes)
            }
            try budget.reserveWorkspace(size * 3 * 4 + strategy.coveredCells * 3 * 4)
            let acX = coefficients.baseX + Float(coefficients.xSlopes[tile]) / Float(coefficients.colourFactor)
            let acB = coefficients.baseB + Float(coefficients.bSlopes[tile]) / Float(coefficients.colourFactor)
            let invQuant = invGlobal / Float(strategy.quantisation)
            // LLF coefficients are a forward transform of the covered DC cells,
            // resampled into the full transform's low-frequency corner.
            if strategy.coveredCells == 1 {
                let dcIdx = y &* bx &+ x
                block0[0] = dc[0][dcIdx]
                block1[0] = dc[1][dcIdx]
                block2[0] = dc[2][dcIdx]
            } else {
                let low0 = try lowFrequencies(dc[0], stride: bx, strategy: strategy, budget: budget)
                let low1 = try lowFrequencies(dc[1], stride: bx, strategy: strategy, budget: budget)
                let low2 = try lowFrequencies(dc[2], stride: bx, strategy: strategy, budget: budget)
                let cx = strategy.cellsX, cy = strategy.cellsY
                for yy in 0..<cy {
                    let dstRow = yy &* columns
                    let srcRow = yy &* cx
                    for xx in 0..<cx {
                        block0[dstRow &+ xx] = low0[srcRow &+ xx]
                        block1[dstRow &+ xx] = low1[srcRow &+ xx]
                        block2[dstRow &+ xx] = low2[srcRow &+ xx]
                    }
                }
            }
            let colShift = codedColumns.trailingZeroBitCount
            let colMask = codedColumns &- 1
            let llfRows = codedRows &>> 3
            let llfCols = codedColumns &>> 3
            let coeffOffset = strategy.coefficientOffset
            try weights.withUnsafeBufferPointer { wBuf in
                try coefficients.ac[0].withUnsafeBufferPointer { ac0Buf in
                    try coefficients.ac[1].withUnsafeBufferPointer { ac1Buf in
                        try coefficients.ac[2].withUnsafeBufferPointer { ac2Buf in
                            try block0.withUnsafeMutableBufferPointer { b0Buf in
                                try block1.withUnsafeMutableBufferPointer { b1Buf in
                                    try block2.withUnsafeMutableBufferPointer { b2Buf in
                                        let wPtr = wBuf.baseAddress!
                                        let ac0Ptr = ac0Buf.baseAddress! + coeffOffset
                                        let ac1Ptr = ac1Buf.baseAddress! + coeffOffset
                                        let ac2Ptr = ac2Buf.baseAddress! + coeffOffset
                                        let b0Ptr = b0Buf.baseAddress!
                                        let b1Ptr = b1Buf.baseAddress!
                                        let b2Ptr = b2Buf.baseAddress!
                                        let w1Base = wPtr + size
                                        let w2Base = wPtr + (2 &* size)
                                        for k in 0..<size {
                                            if k & 255 == 0 { try budget.checkpoint() }
                                            let row = k &>> colShift, column = k & colMask
                                            if row < llfRows && column < llfCols { continue }
                                            let to = transpose ? column &* columns &+ row : k
                                            let q1 = ac1Ptr[k], q0 = ac0Ptr[k], q2 = ac2Ptr[k]
                                            if (q1 | q0 | q2) == 0 {
                                                b1Ptr[to] = 0
                                                b0Ptr[to] = 0
                                                b2Ptr[to] = 0
                                                continue
                                            }
                                            let luma = adjust(q1, channel: 1, numericalMode: numericalMode) / w1Base[k] * invQuant
                                            b1Ptr[to] = luma
                                            b0Ptr[to] = adjust(q0, channel: 0, numericalMode: numericalMode) / wPtr[k] * invQuant * dm0 + acX * luma
                                            b2Ptr[to] = adjust(q2, channel: 2, numericalMode: numericalMode) / w2Base[k] * invQuant * dm2 + acB * luma
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            for c in 0..<3 {
                let applyChannel = { (blkBuf: UnsafeBufferPointer<Float>) throws in
                    let slice = UnsafeBufferPointer(rebasing: blkBuf[0..<size])
                    if isAFV || isSmall {
                        guard let dct4x4, let dct4x8, let dct8x4 else { throw VarDCTError.invalidTransform }
                        try smallPixels.withUnsafeMutableBufferPointer { spBuf in
                            if isAFV {
                                try VarDCTAFV.inverse(slice, kind: identifier - 14, into: spBuf,
                                                      dct4x4: dct4x4, dct4x8: dct4x8, scratch: &scratch, budget: budget)
                            } else {
                                try VarDCTSmallTransforms.inverse(slice, identifier: identifier, into: spBuf,
                                                                  dct4x4: dct4x4, dct4x8: dct4x8, dct8x4: dct8x4,
                                                                  scratch: &scratch, budget: budget)
                            }
                            try copyBlock(UnsafeBufferPointer(spBuf), into: &planes[c], x: x * 8, y: y * 8,
                                          rows: rows, columns: columns, stride: width, budget: budget)
                        }
                    } else {
                        guard let transform = transforms[identifier] else { throw VarDCTError.invalidTransform }
                        try transform.apply(slice, workspace: &scratch)
                        try scratch.withValues {
                            try copyBlock($0, into: &planes[c], x: x * 8, y: y * 8,
                                          rows: rows, columns: columns, stride: width, budget: budget)
                        }
                    }
                }
                if c == 0 {
                    try block0.withUnsafeBufferPointer(applyChannel)
                } else if c == 1 {
                    try block1.withUnsafeBufferPointer(applyChannel)
                } else {
                    try block2.withUnsafeBufferPointer(applyChannel)
                }
            }
        }
        if e.frame.loopFilter.gab {
            for c in 0..<3 {
                planes[c] = try Gaborish.apply(planes[c], width: e.width, height: e.height, stride: width, budget: budget)
            }
        } else if width != e.width || height != e.height {
            try budget.reserveWorkspace(e.width * e.height * 3 * 4)
            for c in 0..<3 {
                var tight = [Float](repeating: 0, count: e.width * e.height)
                for y in 0..<e.height {
                    try budget.checkpoint()
                    for x in 0..<e.width { tight[y * e.width + x] = planes[c][y * width + x] }
                }
                planes[c] = tight
            }
        }
        if e.frame.loopFilter.epfIters > 0 {
            planes = try EdgePreservingFilter.apply(planes, width: e.width, height: e.height,
                iterations: Int(e.frame.loopFilter.epfIters), quantisation: coefficients.quantFields,
                sharpness: coefficients.sharpness, globalScale: coefficients.globalScale, budget: budget)
        }
        try budget.checkpoint()
        return planes
    }

    /// Both buffers are synchronously borrowed, and the validated strategy map
    /// proves the source extent and destination rectangle. Establish destination
    /// uniqueness once per block instead of once per output sample.
    private static func copyBlock(_ pixels: UnsafeBufferPointer<Float>, into plane: inout [Float],
                                  x: Int, y: Int, rows: Int, columns: Int, stride: Int,
                                  budget: ScalarOperationBudget) throws {
        try plane.withUnsafeMutableBufferPointer { destination in
            for row in 0..<rows {
                try budget.checkpoint()
                let sourceOffset = row * columns, destinationOffset = (y + row) * stride + x
                for column in 0..<columns {
                    destination[destinationOffset + column] = pixels[sourceOffset + column]
                }
            }
        }
    }

    @inline(__always)
    private static func adjust(_ value: Int32, channel: Int, numericalMode: VarDCTNumericalMode) -> Float {
        // Avoid abs/negation of Int32.min inherited from the predecessor.
        if value == 0 { return 0 }
        if value == 1 || value == -1 {
            let b: Float
            switch channel {
            case 0: b = 1 - 0.05465007330715401
            case 1: b = 1 - 0.07005449891748593
            default: b = 1 - 0.049935103337343655
            }
            return value == 1 ? b : -b
        }
        let q = Float(value)
        switch numericalMode {
        case .scalarNearest: return q - 0.145 / q
        case .libjxl012ARMInteger:
            return q.addingProduct(-0.145, VarDCTReferenceNumerics.reciprocalEstimate(value))
        }
    }

    private static let scales1: [Double] = [1]
    private static let scales2: [Double] = [1, 1.108937353592731823]
    private static let scales4: [Double] = [1, 1.025760096781116015, 1.108937353592731823, 1.270559368765487251]
    private static let scales8: [Double] = [
        1, 1.0063534990068217, 1.0257600967811158, 1.0593017296817173,
        1.1089373535927318, 1.1777765381970435, 1.2705593687654873, 1.3944898413647777
    ]
    private static let cos1: [Double] = [1]
    private static let cos2: [Double] = makeCosTable(2)
    private static let cos4: [Double] = makeCosTable(4)
    private static let cos8: [Double] = makeCosTable(8)
    private static func makeCosTable(_ n: Int) -> [Double] {
        var table = [Double](repeating: 0, count: n * n)
        for u in 0..<n {
            for x in 0..<n {
                table[u * n + x] = cos((Double(x) + 0.5) * Double(u) * .pi / Double(n))
            }
        }
        return table
    }
    private static func scaleAndCos(_ n: Int) -> ([Double], [Double])? {
        switch n {
        case 1: return (scales1, cos1)
        case 2: return (scales2, cos2)
        case 4: return (scales4, cos4)
        case 8: return (scales8, cos8)
        default: return nil
        }
    }

    private static func lowFrequencies(_ dc: [Float], stride: Int,
                                       strategy: VarDCTStrategyMap.Transform,
                                       budget: ScalarOperationBudget) throws -> [Float] {
        let rows = strategy.cellsY, columns = strategy.cellsX
        guard rows <= 8, columns <= 8 else { throw VarDCTError.unsupportedStrategy(strategy.identifier) }
        try budget.reserveWorkspace(rows * columns * 4)
        if rows == 1, columns == 1 { return [dc[strategy.y * stride + strategy.x]] }
        // Scales are DCTResampleScales<N,8*N> from the pinned predecessor's
        // LowestFrequenciesFromDC (libjxl dct_scales.h).
        guard let (sx, cx) = scaleAndCos(columns), let (sy, cy) = scaleAndCos(rows) else {
            throw VarDCTError.invalidTransform
        }
        var output = [Float](repeating: 0, count: rows * columns)
        let rootTwo = sqrt(2.0)
        let invCount = 1.0 / Double(rows * columns)
        try dc.withUnsafeBufferPointer { dcBuf in
            let dcPtr = dcBuf.baseAddress!
            for v in 0..<rows {
                let vCosBase = v &* rows
                let vFactor = (v == 0 ? 1.0 : rootTwo) * invCount
                let syV = sy[v]
                for u in 0..<columns {
                    try budget.checkpoint()
                    let uCosBase = u &* columns
                    var sum: Double = 0
                    for y in 0..<rows {
                        let cY = cy[vCosBase &+ y]
                        let rowBase = (strategy.y &+ y) &* stride &+ strategy.x
                        for x in 0..<columns {
                            let sample = Double(dcPtr[rowBase &+ x])
                            sum += sample * cx[uCosBase &+ x] * cY
                        }
                    }
                    let factor = (u == 0 ? 1.0 : rootTwo) * vFactor
                    let value = Float(sum * factor * sx[u] * syV)
                    guard value.isFinite else { throw VarDCTError.nonFiniteSample }
                    output[v &* columns &+ u] = value
                }
            }
        }
        return output
    }
    private static func smoothDC(_ planes: inout [[Float]], width: Int, height: Int,
                                 factors: [Float], budget: ScalarOperationBudget) throws {
        guard width > 2, height > 2 else { return }
        try budget.reserveWorkspace(width * height * 3 * 4)
        var res0 = planes[0]
        var res1 = planes[1]
        var res2 = planes[2]
        let w1: Float = 0.20345139757231578, w2: Float = 0.0334829185968739
        let w0: Float = 1 - 4 * (w1 + w2)
        let f0 = factors[0], f1 = factors[1], f2 = factors[2]
        try planes[0].withUnsafeBufferPointer { b0 in
            try planes[1].withUnsafeBufferPointer { b1 in
                try planes[2].withUnsafeBufferPointer { b2 in
                    try res0.withUnsafeMutableBufferPointer { r0 in
                        try res1.withUnsafeMutableBufferPointer { r1 in
                            try res2.withUnsafeMutableBufferPointer { r2 in
                                let p0 = b0.baseAddress!, p1 = b1.baseAddress!, p2 = b2.baseAddress!
                                let d0 = r0.baseAddress!, d1 = r1.baseAddress!, d2 = r2.baseAddress!
                                for y in 1..<(height - 1) {
                                    for x in 1..<(width - 1) {
                                        if x & 255 == 1 { try budget.checkpoint() }
                                        let index = y &* width &+ x
                                        var gap: Float = 0.5
                                        let c0 = (p0[index - width - 1] + p0[index - width + 1]) + (p0[index + width - 1] + p0[index + width + 1])
                                        let sd0 = (p0[index - 1] + p0[index + 1]) + (p0[index - width] + p0[index + width])
                                        let s0 = c0 * w2 + sd0 * w1 + p0[index] * w0
                                        guard s0.isFinite else { throw VarDCTError.nonFiniteSample }
                                        gap = max(gap, abs((p0[index] - s0) / f0))

                                        let c1 = (p1[index - width - 1] + p1[index - width + 1]) + (p1[index + width - 1] + p1[index + width + 1])
                                        let sd1 = (p1[index - 1] + p1[index + 1]) + (p1[index - width] + p1[index + width])
                                        let s1 = c1 * w2 + sd1 * w1 + p1[index] * w0
                                        guard s1.isFinite else { throw VarDCTError.nonFiniteSample }
                                        gap = max(gap, abs((p1[index] - s1) / f1))

                                        let c2 = (p2[index - width - 1] + p2[index - width + 1]) + (p2[index + width - 1] + p2[index + width + 1])
                                        let sd2 = (p2[index - 1] + p2[index + 1]) + (p2[index - width] + p2[index + width])
                                        let s2 = c2 * w2 + sd2 * w1 + p2[index] * w0
                                        guard s2.isFinite else { throw VarDCTError.nonFiniteSample }
                                        gap = max(gap, abs((p2[index] - s2) / f2))

                                        let factor = max(0, 3 - 4 * gap)
                                        d0[index] = p0[index] + (s0 - p0[index]) * factor
                                        d1[index] = p1[index] + (s1 - p1[index]) * factor
                                        d2[index] = p2[index] + (s2 - p2[index]) * factor
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        planes = [res0, res1, res2]
    }
}
