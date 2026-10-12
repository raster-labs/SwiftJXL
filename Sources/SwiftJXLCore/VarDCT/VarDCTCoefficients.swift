// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Codec/JXLDecoder.swift and VarDCT entropy modules at
// 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause terms; see libjxl-LICENSE.txt.
import Foundation

/// Internal one-DC-group, single-pass coefficient profile. Coefficients stay in
/// codestream orientation and XYB order; final pixel storage is a later stage.
package struct VarDCTCoefficients: Sendable {
    package let envelope: VarDCTFrameEnvelope
    package let blocksX: Int, blocksY: Int
    package let strategies: VarDCTStrategyMap
    package let dc: [[Int32]], ac: [[Int32]]
    package let alpha: [Int32]?
    package let quantFields: [UInt32], sharpness: [Int32]
    package let xSlopes: [Int32], bSlopes: [Int32]
    package let globalScale: UInt32, quantDC: UInt32, dcExtraPrecision: Int
    package let colourFactor: UInt32, baseX: Float, baseB: Float, dcX: Int32, dcB: Int32

    package static func read(_ envelope: VarDCTFrameEnvelope) throws -> Self {
        guard envelope.dcGroupsX == 1, envelope.dcGroupsY == 1,
              envelope.frame.passes.numPasses == 1,
              (envelope.metadata.extraChannels.isEmpty || (envelope.width <= envelope.groupDimension && envelope.height <= envelope.groupDimension)),
              !envelope.frame.loopFilter.hasCustomParameters else { throw ScalarModularError.unsupportedProfile }
        var reader = try CoefficientReader(envelope: envelope)
        return try reader.read()
    }
}

private struct CoefficientReader {
    let envelope: VarDCTFrameEnvelope
    var r: BitReader
    let budget: ScalarOperationBudget
    typealias Entropy = (ModularTree, EntropySectionHeader, MultiClusterCodebook)
    var global: Entropy?

    init(envelope: VarDCTFrameEnvelope) throws {
        self.envelope = envelope; budget = envelope.budget
        r = try envelope.section(0)
    }
    mutating func begin(_ index: Int) throws {
        if envelope.sectionCount != 1 { r = try envelope.section(index) }
    }
    mutating func end() throws {
        if envelope.sectionCount != 1 {
            try r.expectZeroPadding()
            guard r.bitsRemaining == 0 else { throw ScalarModularError.invalidInput("Unconsumed VarDCT section") }
        }
    }
    mutating func tree() throws -> Entropy {
        let header = try EntropySectionHeader.read(from: &r, numContexts: 6)
        let codebook = try MultiClusterCodebook.read(from: &r, header: header)
        var stream = TokenStreamReader(header: header, codebook: codebook)
        let tree = try ModularTree.decode(from: &r, stream: &stream)
        try stream.finish()
        let post = try EntropySectionHeader.read(from: &r, numContexts: tree.leafCount)
        return (tree, post, try MultiClusterCodebook.read(from: &r, header: post))
    }
    mutating func modular(_ geometry: [(Int, Int)], group: Int32) throws -> [[Int32]] {
        let header = try GroupHeader.read(from: &r)
        let entropy: Entropy
        if header.useGlobalTree {
            guard let global else { throw ScalarModularError.invalidInput("Missing global Modular tree") }
            entropy = global
        } else { entropy = try tree() }
        try ModularImage.admitDescriptors(geometry.count, budget: budget)
        var image = try ModularImage(channels: geometry.map { try ModularChannel(width: $0.0, height: $0.1) })
        let transforms = try metaApplyTransforms(image: &image, transforms: header.transforms, budget: budget)
        let shapes = image.channels.map { ModularChannelGeometry(width: $0.width, height: $0.height) }
        // DecodeAllChannels owns Int32 planes and per-channel predictor rows.
        // Admit transformed shapes before either allocation, including possible
        // capacity/COW overlap and LZ replay tables.
        for channel in image.channels {
            try budget.reserveWorkspace(ScalarOperationBudget.sum(
                ScalarOperationBudget.product(channel.sampleCount, 12),
                ScalarOperationBudget.sum(ScalarOperationBudget.product(channel.width + 2, 192), 1024)))
        }
        try budget.reserveWorkspace(ScalarOperationBudget.product(entropy.2.ansCounts.count, 64 * 1024))
        var stream = TokenStreamReader(header: entropy.1, codebook: entropy.2,
            distanceMultiplier: shapes.map(\.width).max() ?? 0)
        let values = try decodeAllChannels(channels: shapes, groupId: group, tree: entropy.0,
            stream: &stream, from: &r, wpHeader: header.wpHeader)
        try stream.finish()
        for i in image.channels.indices { image.channels[i].pixels = values[i] }
        try applyInverseTransforms(image: &image, transforms: transforms, bitDepth: 16, budget: budget)
        guard image.channels.count == geometry.count else { throw ScalarModularError.invalidInput("Invalid Modular channel count") }
        for i in geometry.indices {
            guard image.channels[i].width == geometry[i].0, image.channels[i].height == geometry[i].1 else {
                throw ScalarModularError.invalidInput("Invalid Modular channel dimensions")
            }
        }
        return image.channels.map(\.pixels)
    }

    mutating func read() throws -> VarDCTCoefficients {
        let bx = (envelope.width + 7) / 8, by = (envelope.height + 7) / 8, blocks = bx * by
        let groups = envelope.groupsX * envelope.groupsY
        // All coefficient planes, their COW overlap, predictor workspace and
        // bounded metadata. Entropy allocations receive their own reader charges.
        try budget.reserveWorkspace(ScalarOperationBudget.sum(ScalarOperationBudget.product(blocks, 3 * 64 * 8 + 256), 65536))
        guard try r.readBit() else { throw ScalarModularError.unsupportedProfile } // default DC quantisation
        let scale = try r.readU32((.offset(constant: 1, extraBits: 11), .offset(constant: 2049, extraBits: 11),
            .offset(constant: 4097, extraBits: 12), .offset(constant: 8193, extraBits: 16)))
        let quantDC = try r.readU32((.literal(16), .offset(constant: 1, extraBits: 5),
            .offset(constant: 1, extraBits: 8), .offset(constant: 1, extraBits: 16)))
        let contexts = try JPEGBridgeBlockContext.read(from: &r)
        var factor: UInt32 = 84, baseX: Float = 0, baseB: Float = 1, dcX: Int32 = 0, dcB: Int32 = 0
        if try !r.readBit() {
            factor = try r.readU32((.literal(84), .literal(256), .offset(constant: 2, extraBits: 8), .offset(constant: 258, extraBits: 16)))
            baseX = halfToFloat(UInt16(try r.read(bits: 16))); baseB = halfToFloat(UInt16(try r.read(bits: 16)))
            guard baseX.isFinite, baseB.isFinite, abs(baseX) <= 4, abs(baseB - 1) <= 4 else {
                throw ScalarModularError.invalidInput("Invalid colour correlation")
            }
            dcX = Int32(try r.read(bits: 8)) - 128; dcB = Int32(try r.read(bits: 8)) - 128
        }
        if try r.readBit() { global = try tree() }
        let alpha: [Int32]?
        if envelope.metadata.extraChannels.isEmpty { alpha = nil }
        else {
            alpha = try modular([(envelope.width, envelope.height)], group: 0)[0]
            let maximum = Int32((1 << envelope.metadata.bitDepth.bitsPerSample) - 1)
            guard alpha?.allSatisfy({ $0 >= 0 && $0 <= maximum }) == true else {
                throw ScalarModularError.invalidInput("Invalid alpha sample")
            }
        }
        try end(); try begin(1)
        let precision = Int(try r.read(bits: 2))
        let storedDC = try modular([(bx, by), (bx, by), (bx, by)], group: 1)
        let dc = [storedDC[1], storedDC[0], storedDC[2]]
        let count = Int(try r.read(bits: Int(ceilLog2(UInt32(blocks))))) + 1
        guard count <= blocks else { throw VarDCTError.invalidTransform }
        let tw = (bx + 7) / 8, th = (by + 7) / 8
        let metadata = try modular([(tw, th), (tw, th), (count, 2), (bx, by)], group: 3)
        let strategies = try VarDCTStrategyMap.read(metadata[2], count: count, width: bx, height: by,
            groupBlocks: envelope.groupDimension / 8, budget: budget)
        guard metadata[0].allSatisfy({ (-128...127).contains($0) }),
              metadata[1].allSatisfy({ (-128...127).contains($0) }),
              metadata[3].allSatisfy({ (0...7).contains($0) }) else {
            throw ScalarModularError.invalidInput("Invalid VarDCT block metadata")
        }
        let qf = strategies.indices.map { strategies.transforms[$0].quantisation }
        try end(); try begin(2)
        guard try r.readBit() else { throw ScalarModularError.unsupportedProfile } // default AC matrices
        let histograms = 1 + Int(try r.read(bits: Int(ceilLog2(UInt32(groups)))))
        guard histograms <= groups else { throw ScalarModularError.invalidInput("Invalid histogram count") }
        let orders = try VarDCTOrders.read(from: &r, usedBuckets: Set(strategies.transforms.map(\.orderBucket)), budget: budget)
        let header = try EntropySectionHeader.read(from: &r, numContexts: histograms * contexts.contexts,
            maximumContexts: 64 * 16 * 495)
        let codebook = try MultiClusterCodebook.read(from: &r, header: header)
        try end()
        var ac = (0..<3).map { _ in [Int32](repeating: 0, count: blocks * 64) }
        let bpg = envelope.groupDimension / 8
        for group in 0..<groups {
            try begin(3 + group)
            let histogram = Int(try r.read(bits: Int(ceilLog2(UInt32(histograms)))))
            guard histogram < histograms else { throw ScalarModularError.invalidInput("Invalid histogram selector") }
            var stream = TokenStreamReader(header: header, codebook: codebook)
            let x0 = group % envelope.groupsX * bpg, y0 = group / envelope.groupsX * bpg
            let w = min(bpg, bx - x0), h = min(bpg, by - y0)
            var nonzero = (0..<3).map { _ in [Int32](repeating: 0, count: w * h) }
            for y in 0..<h { for x in 0..<w {
                try budget.checkpoint()
                let index = (y0 + y) * bx + x0 + x
                let transform = strategies.transforms[strategies.indices[index]]
                guard transform.x == x0 + x, transform.y == y0 + y else { continue }
                guard let order = orders[transform.orderBucket], order.count == 3 else { throw VarDCTError.invalidTransform }
                let dcValues = dc.map { $0[index] }
                for c in [1, 0, 2] {
                    let prediction: UInt32 = y == 0 ? (x == 0 ? 32 : UInt32(nonzero[c][x - 1]))
                        : (x == 0 ? UInt32(nonzero[c][(y - 1) * w])
                           : UInt32((nonzero[c][(y - 1) * w + x] + nonzero[c][y * w + x - 1] + 1) / 2))
                    let context = try contexts.varDCTContext(dcValues: dcValues, quantisation: qf[index], channel: c, order: transform.orderBucket)
                    let decoded = try contexts.readVarDCTBlock(prediction: prediction, blockContext: context,
                        offset: histogram * contexts.contexts, order: order[c], coveredCells: transform.coveredCells,
                        stream: &stream, from: &r, budget: budget)
                    let density = Int32((decoded.nonzeros + transform.coveredCells - 1) / transform.coveredCells)
                    for yy in y..<(y + transform.cellsY) { for xx in x..<(x + transform.cellsX) {
                        nonzero[c][yy * w + xx] = density
                    } }
                    for k in decoded.coefficients.indices {
                        ac[c][transform.coefficientOffset + k] = decoded.coefficients[k]
                    }
                }
            } }
            try stream.finish(); try end()
        }
        if envelope.sectionCount == 1 {
            try r.expectZeroPadding()
            guard r.bitsRemaining == 0 else { throw ScalarModularError.invalidInput("Trailing VarDCT bits") }
        }
        return VarDCTCoefficients(envelope: envelope, blocksX: bx, blocksY: by, strategies: strategies, dc: dc, ac: ac, alpha: alpha,
            quantFields: qf, sharpness: metadata[3], xSlopes: metadata[0], bSlopes: metadata[1],
            globalScale: scale, quantDC: quantDC, dcExtraPrecision: precision,
            colourFactor: factor, baseX: baseX, baseB: baseB, dcX: dcX, dcB: dcB)
    }
}
