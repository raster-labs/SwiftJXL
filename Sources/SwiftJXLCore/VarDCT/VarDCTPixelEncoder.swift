// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Codec/VarDCTEncoder.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e. Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause; see libjxl-LICENSE.txt.
import Foundation

/// Bounded single-cell transform search with explicit predecessor prefilter
/// and adaptive quantisation. Larger-region hierarchical search remains pending.
package enum VarDCTPixelEncoder {
    struct Coefficients {
        let width: Int, height: Int, blocksX: Int, blocksY: Int
        let bits: Int, grayscale: Bool, hasAlpha: Bool
        let globalScale: UInt32
        let quantDC: UInt32 = 17
        let quantAC: [Int32], strategies: [Int32]
        let gaborish: Bool, dcSmoothing: Bool
        let dc: [[Int32]], ac: [[Int32]]
    }

    /// The caller keeps the source owner and its synchronous read borrow alive
    /// until return. Neither the raw pointer nor any derived pointer escapes.
    /// Only admitted algorithm and writer workspace is allocated.
    package static func encode(_ bytes: UnsafeRawBufferPointer,
                               layouts: [ModularChannelLayout], bitsPerSample: Int,
                               grayscale: Bool, alphaAssociated: Bool?, distance: Float,
                               gaborish: Bool = false, adaptiveQuantisation: Bool = false, dcSmoothing: Bool = false,
                               smallStrategySearch: Bool = false,
                               budget: ScalarOperationBudget) throws -> Data {
        try budget.checkpoint()
        guard let first = layouts.first, (8...16).contains(bitsPerSample),
              distance.isFinite, distance > 0,
              layouts.count == (grayscale ? 1 : 3) + (alphaAssociated == nil ? 0 : 1),
              layouts.allSatisfy({ $0.width == first.width && $0.height == first.height &&
                  $0.storageBits >= bitsPerSample && $0.requiredBytes <= bytes.count }) else {
            throw ScalarModularError.invalidInput("Incompatible VarDCT source or distance")
        }
        guard first.width <= 2048, first.height <= 2048, alphaAssociated != true,
              alphaAssociated == nil || (first.width <= 256 && first.height <= 256) else {
            throw ScalarModularError.unsupportedProfile
        }
        let bx = (first.width + 7) / 8, by = (first.height + 7) / 8
        let blocks = try ScalarOperationBudget.product(bx, by), padded = try ScalarOperationBudget.product(blocks, 64)
        let limit = min(budget.maximumCompressedBytes,
            try ScalarOperationBudget.sum(ScalarOperationBudget.product(padded, 12), 65536))
        // Coefficient owners, COW/capacity headroom, constant histogram/codebook
        // inventory, and section/combined BitWriter growth overlap. Per-DCT
        // application scratch is separately charged by the transform plan.
        try budget.reserveOutput(limit)
        try budget.reserveWorkspace(ScalarOperationBudget.sum(ScalarOperationBudget.product(padded, 32),
            ScalarOperationBudget.sum(ScalarOperationBudget.product(limit, 6), 4 * 1024 * 1024)))
        let source = VarDCTBorrowedSource(bytes: bytes, layouts: layouts, maximum: (Int32(1) << bitsPerSample) - 1)
        let scale = UInt32(max(1, min(65535, (5111 / max(0.05, distance)).rounded())))
        let transform = try ScaledDCT(rows: 8, columns: 8, direction: .forward, budget: budget)
        let weights = try VarDCTQuantWeights.make(identifier: 0, rows: 8, columns: 8, budget: budget)
        var dc = (0..<3).map { _ in [Int32](repeating: 0, count: blocks) }
        var ac = (0..<3).map { _ in [Int32](repeating: 0, count: padded) }
        var patch = (0..<3).map { _ in [Float](repeating: 0, count: 64) }
        var quantAC = [Int32](repeating: 5, count: blocks)
        var strategies = [Int32](repeating: 0, count: blocks)
        let smallPlan = try smallStrategySearch ? VarDCTSmallAnalysis(budget: budget) : nil
        var smallWeights: [Int: [Float]] = [:]
        if smallStrategySearch {
            for id in [0,1,2,3,12,13,14,15,16,17] {
                smallWeights[id] = try VarDCTQuantWeights.make(identifier: id, rows: 8, columns: 8, budget: budget)
            }
        }
        var prepared: [[Float]]? = nil
        if gaborish || adaptiveQuantisation {
            let visible = try ScalarOperationBudget.product(first.width, first.height)
            try budget.reserveWorkspace(ScalarOperationBudget.product(visible, 3 * MemoryLayout<Float>.stride))
            var planes = (0..<3).map { _ in [Float](repeating: 0, count: visible) }
            for y in 0..<first.height { for x in 0..<first.width {
                if x & 255 == 0 { try budget.checkpoint() }
                func linear(_ c: Int) throws -> Double {
                    let v = Double(try source.sample(channel: c, x: x, y: y)) / Double(source.maximum)
                    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                }
                let r = try linear(0), g = try grayscale ? r : linear(1), b = try grayscale ? r : linear(2)
                let p = try DefaultOpsin.forward((r,g,b)), i = y * first.width + x
                planes[0][i] = Float(p.X); planes[1][i] = Float(p.Y); planes[2][i] = Float(p.B)
            } }
            if gaborish {
                for c in 0..<3 { planes[c] = try VarDCTEncoderPreparation.inverseGaborish(planes[c],
                    width: first.width, height: first.height, budget: budget) }
            }
            prepared = planes
        }
        let dcScale: [Double] = [4096, 512, 256].map { Double(scale) * 17 * $0 / 65536 }
        for y in 0..<by { for x in 0..<bx {
            try budget.checkpoint()
            for py in 0..<8 { for px in 0..<8 {
                let sx = min(first.width - 1, x * 8 + px), sy = min(first.height - 1, y * 8 + py)
                if let prepared {
                    let sourceIndex = sy * first.width + sx, target = py * 8 + px
                    for c in 0..<3 { patch[c][target] = prepared[c][sourceIndex] }
                    continue
                }
                func linear(_ channel: Int) throws -> Double {
                    let encoded = Double(try source.sample(channel: channel, x: sx, y: sy)) / Double(source.maximum)
                    return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
                }
                let r = try linear(0), g = try grayscale ? r : linear(1), b = try grayscale ? r : linear(2)
                let p = try DefaultOpsin.forward((r, g, b)), i = py * 8 + px
                patch[0][i] = Float(p.X); patch[1][i] = Float(p.Y); patch[2][i] = Float(p.B - p.Y)
            } }
            let block = y * bx + x
            if adaptiveQuantisation { quantAC[block] = try VarDCTEncoderPreparation.quantisation(patch, distance: distance) }
            if prepared != nil { for k in 0..<64 { patch[2][k] -= patch[1][k] } }
            if let smallPlan {
                func trial(_ id: Int) throws -> (dc: [Int32], ac: [[Int32]], cost: Int) {
                    try budget.checkpoint()
                    try budget.reserveWorkspace(256 * MemoryLayout<Int32>.stride)
                    guard let weights = smallWeights[id] else { throw VarDCTError.invalidTransform }
                    var dc = [Int32](repeating: 0, count: 3)
                    var ac = (0..<3).map { _ in [Int32](repeating: 0, count: 64) }
                    var cost = 0
                    for c in 0..<3 {
                        let values = try smallPlan.apply(patch[c], identifier: id)
                        dc[c] = try quantise(Double(values[0]) * dcScale[c])
                        for k in 1..<64 { ac[c][k] = try quantise(Double(values[k]) * Double(weights[c * 64 + k]) * Double(scale) / 65536 * Double(quantAC[block])) }
                        cost += tokenCost(ac[c])
                    }
                    return (dc,ac,cost)
                }
                var best = try trial(0), chosen = 0
                let initialCost = best.cost
                if initialCost > 54 {
                    // Later equal-cost choices reproduce the predecessor's
                    // explicit tie priority, including the four AFV orientations.
                    for id in [13,12,3,2,1,17,16,15,14] where id < 14 || initialCost > 120 {
                        let candidate = try trial(id)
                        if candidate.cost <= best.cost { best = candidate; chosen = id }
                    }
                }
                strategies[block] = Int32(chosen)
                for c in 0..<3 {
                    dc[c][block] = best.dc[c]
                    for k in 1..<64 { ac[c][block * 64 + k] = best.ac[c][k] }
                }
                continue
            }
            for c in 0..<3 {
                let result = try transform.apply(patch[c])
                dc[c][block] = try quantise(Double(result[0]) * dcScale[c])
                for k in 1..<64 {
                    // The codestream's square-DCT coefficient layout transposes
                    // the ordinary row-major analysis transform.
                    let value = result[(k % 8) * 8 + k / 8]
                    ac[c][block * 64 + k] = try quantise(Double(value) * Double(weights[c * 64 + k]) * Double(scale) / 65536 * Double(quantAC[block]))
                }
            }
        } }
        let coefficients = Coefficients(width: first.width, height: first.height, blocksX: bx, blocksY: by,
            bits: bitsPerSample, grayscale: grayscale, hasAlpha: alphaAssociated != nil, globalScale: scale, quantAC: quantAC, strategies: strategies, gaborish: gaborish, dcSmoothing: dcSmoothing, dc: dc, ac: ac)
        return try ScalarEncodingWork.$current.withValue(.init(budget: budget, writerByteLimit: limit)) {
            let data = try VarDCTFrameWriter(coefficients: coefficients, source: source, budget: budget, limit: limit).write()
            try ScalarEncodingWork.checkpoint()
            return data
        }
    }

    private static func tokenCost(_ coefficients: [Int32]) -> Int {
        let order = VarDCTFrameWriter.order
        var last = 0, magnitudeBits = 0
        for k in 1..<64 {
            let value = coefficients[order[k]]
            if value != 0 { last = k; magnitudeBits += 32 - value.magnitude.leadingZeroBitCount }
        }
        return 4 + 2 * last + magnitudeBits
    }

    private static func quantise(_ value: Double) throws -> Int32 {
        let rounded = value.rounded()
        guard rounded.isFinite, rounded >= Double(Int32.min), rounded <= Double(Int32.max) else {
            throw ScalarModularError.invalidInput("VarDCT coefficient exceeds integer precision")
        }
        return Int32(rounded)
    }
}

/// Operation-local synchronous borrow; intentionally not Sendable. The encoder
/// validates every layout before construction and retains no instance on return.
struct VarDCTBorrowedSource {
    let bytes: UnsafeRawBufferPointer
    let layouts: [ModularChannelLayout]
    let maximum: Int32
    func sample(channel: Int, x: Int, y: Int) throws -> Int32 {
        let layout = layouts[channel], p = layout.offset + y * layout.rowBytes + x * layout.pixelStride
        let value: Int32
        if layout.storageBits == 8 { value = Int32(bytes[p]) }
        else if layout.littleEndian { value = Int32(bytes[p]) | Int32(bytes[p + 1]) << 8 }
        else { value = Int32(bytes[p]) << 8 | Int32(bytes[p + 1]) }
        guard value <= maximum else { throw ScalarModularError.invalidInput("Source sample exceeds meaningful precision") }
        return value
    }
}
