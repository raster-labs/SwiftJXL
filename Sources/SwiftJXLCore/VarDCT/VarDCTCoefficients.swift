// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Codec/JXLDecoder.swift and VarDCT entropy modules at
// 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause terms; see libjxl-LICENSE.txt.
import Foundation

/// Internal bounded, single-pass coefficient profile. Coefficients stay in
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
        guard envelope.frame.passes.numPasses == 1,
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
    mutating func modular(_ geometry: [(Int, Int)], group: Int32, bitDepth: Int = 16) throws -> [[Int32]] {
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
        try applyInverseTransforms(image: &image, transforms: transforms, bitDepth: bitDepth, budget: budget)
        guard image.channels.count == geometry.count else { throw ScalarModularError.invalidInput("Invalid Modular channel count") }
        for i in geometry.indices {
            guard image.channels[i].width == geometry[i].0, image.channels[i].height == geometry[i].1 else {
                throw ScalarModularError.invalidInput("Invalid Modular channel dimensions")
            }
        }
        return image.channels.map(\.pixels)
    }

    func place(_ source: [Int32], into destination: inout [Int32], x: Int, y: Int,
               width: Int, height: Int, stride: Int) throws {
        guard source.count == width * height, x >= 0, y >= 0, width <= stride - x,
              (y + height) * stride <= destination.count else {
            throw ScalarModularError.invalidInput("Invalid VarDCT region")
        }
        for row in 0..<height {
            try budget.checkpoint()
            for column in 0..<width { destination[(y + row) * stride + x + column] = source[row * width + column] }
        }
    }

    mutating func read() throws -> VarDCTCoefficients {
        let bx = (envelope.width + 7) / 8, by = (envelope.height + 7) / 8, blocks = bx * by
        let groups = envelope.groupsX * envelope.groupsY
        let dcGroups = envelope.dcGroupsX * envelope.dcGroupsY
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
        var alpha: [Int32]?
        var alphaPalette: [Int32]?
        var alphaTransform: ModularTransform?
        let groupedAlpha = !envelope.metadata.extraChannels.isEmpty &&
            (envelope.width > envelope.groupDimension || envelope.height > envelope.groupDimension)
        if envelope.metadata.extraChannels.isEmpty { alpha = nil }
        else if groupedAlpha {
            // One simple palette preserves the full-resolution deferred index
            // geometry. Squeeze and other transform chains need separate grouping.
            let alphaHeader = try GroupHeader.read(from: &r)
            if !alphaHeader.transforms.isEmpty {
                guard alphaHeader.transforms.count == 1, let transform = alphaHeader.transforms.first,
                      transform.id == .palette, transform.beginC == 0, transform.numC == 1,
                      transform.nbColors > 0, transform.nbColors <= 65536,
                      transform.nbDeltas == 0, transform.palettePredictor == 0 else {
                    throw ScalarModularError.unsupportedProfile
                }
                alphaTransform = transform
            }
            let entropy: Entropy
            if alphaHeader.useGlobalTree {
                guard let global else { throw ScalarModularError.invalidInput("Missing global Modular tree") }
                entropy = global
            } else { entropy = try tree() }
            if let transform = alphaTransform {
                let width = Int(transform.nbColors)
                try budget.reserveWorkspace(ScalarOperationBudget.sum(
                    ScalarOperationBudget.product(width, 12 + 192),
                    ScalarOperationBudget.product(entropy.2.ansCounts.count, 64 * 1024)))
                var stream = TokenStreamReader(header: entropy.1, codebook: entropy.2, distanceMultiplier: width)
                alphaPalette = try decodeAllChannels(channels: [.init(width: width, height: 1)],
                    groupId: 0, tree: entropy.0, stream: &stream, from: &r, wpHeader: alphaHeader.wpHeader)[0]
                try stream.finish()
            } else if !entropy.1.usePrefixCode {
                guard try r.read(bits: 32) == ANSConstants.initialState else {
                    throw ScalarModularError.invalidInput("Invalid empty alpha entropy state")
                }
            }
            try budget.reserveWorkspace(ScalarOperationBudget.product(envelope.width * envelope.height, 8))
            alpha = [Int32](repeating: 0, count: envelope.width * envelope.height)
        } else { alpha = try modular([(envelope.width, envelope.height)], group: 0,
            bitDepth: Int(envelope.metadata.bitDepth.bitsPerSample))[0] }
        try end()
        var precision = 0
        var dc = (0..<3).map { _ in [Int32](repeating: 0, count: blocks) }
        let tw = (bx + 7) / 8, th = (by + 7) / 8
        var xSlopes = [Int32](repeating: 0, count: tw * th)
        var bSlopes = xSlopes, sharpness = [Int32](repeating: 0, count: blocks)
        var transforms: [VarDCTStrategyMap.Transform] = [], indices = [Int](repeating: -1, count: blocks)
        var coefficientOffset = 0
        for group in 0..<dcGroups {
            try begin(1 + group)
            let extra = Int(try r.read(bits: 2))
            if group == 0 { precision = extra }
            else if extra != precision { throw ScalarModularError.unsupportedProfile }
            let x0 = group % envelope.dcGroupsX * envelope.groupDimension
            let y0 = group / envelope.dcGroupsX * envelope.groupDimension
            let w = min(envelope.groupDimension, bx - x0), h = min(envelope.groupDimension, by - y0)
            let storedDC = try modular([(w, h), (w, h), (w, h)], group: Int32(1 + group))
            for c in 0..<3 {
                try place(storedDC[[1, 0, 2][c]], into: &dc[c], x: x0, y: y0, width: w, height: h, stride: bx)
            }
            let count = Int(try r.read(bits: Int(ceilLog2(UInt32(w * h))))) + 1
            guard count <= w * h else { throw VarDCTError.invalidTransform }
            let cw = (w + 7) / 8, ch = (h + 7) / 8
            let metadata = try modular([(cw, ch), (cw, ch), (count, 2), (w, h)],
                group: Int32(1 + 2 * dcGroups + group))
            let local = try VarDCTStrategyMap.read(metadata[2], count: count, width: w, height: h,
                groupBlocks: envelope.groupDimension / 8, budget: budget)
            guard metadata[0].allSatisfy({ (-128...127).contains($0) }),
                  metadata[1].allSatisfy({ (-128...127).contains($0) }),
                  metadata[3].allSatisfy({ (0...7).contains($0) }) else {
                throw ScalarModularError.invalidInput("Invalid VarDCT block metadata")
            }
            try place(metadata[0], into: &xSlopes, x: x0 / 8, y: y0 / 8, width: cw, height: ch, stride: tw)
            try place(metadata[1], into: &bSlopes, x: x0 / 8, y: y0 / 8, width: cw, height: ch, stride: tw)
            try place(metadata[3], into: &sharpness, x: x0, y: y0, width: w, height: h, stride: bx)
            let transformBase = transforms.count
            for t in local.transforms {
                transforms.append(.init(identifier: t.identifier, x: x0 + t.x, y: y0 + t.y,
                    cellsX: t.cellsX, cellsY: t.cellsY, quantisation: t.quantisation,
                    coefficientOffset: coefficientOffset + t.coefficientOffset))
            }
            for y in 0..<h { for x in 0..<w {
                indices[(y0 + y) * bx + x0 + x] = transformBase + local.indices[y * w + x]
            } }
            coefficientOffset += local.coefficientCount
            try end()
        }
        let strategies = VarDCTStrategyMap(width: bx, height: by, transforms: transforms,
            indices: indices, coefficientCount: coefficientOffset)
        let qf = strategies.indices.map { strategies.transforms[$0].quantisation }
        try begin(1 + dcGroups)
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
            try begin(2 + dcGroups + group)
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
            try stream.finish()
            if groupedAlpha {
                let px = x0 * 8, py = y0 * 8
                let pw = min(envelope.groupDimension, envelope.width - px)
                let ph = min(envelope.groupDimension, envelope.height - py)
                let values = try modular([(pw, ph)], group: Int32(1 + 3 * dcGroups + 17 + group),
                    bitDepth: Int(envelope.metadata.bitDepth.bitsPerSample))[0]
                // Drop the optional's reference before modifying its admitted plane.
                if var plane = alpha {
                    alpha = nil
                    try place(values, into: &plane, x: px, y: py, width: pw, height: ph, stride: envelope.width)
                    alpha = plane
                }
            }
            try end()
        }
        if envelope.sectionCount == 1 {
            try r.expectZeroPadding()
            guard r.bitsRemaining == 0 else { throw ScalarModularError.invalidInput("Trailing VarDCT bits") }
        }
        if let transform = alphaTransform, let palette = alphaPalette, let indices = alpha {
            try ModularImage.admitDescriptors(1, budget: budget)
            var image = try ModularImage(channels: [ModularChannel(width: envelope.width, height: envelope.height)])
            let transforms = try metaApplyTransforms(image: &image, transforms: [transform], budget: budget)
            image.channels[0].pixels = palette
            image.channels[1].pixels = indices
            alpha = nil
            try applyInverseTransforms(image: &image, transforms: transforms,
                bitDepth: Int(envelope.metadata.bitDepth.bitsPerSample), budget: budget)
            alpha = image.channels[0].pixels
        }
        if let alpha {
            let maximum = Int32((1 << envelope.metadata.bitDepth.bitsPerSample) - 1)
            guard alpha.allSatisfy({ $0 >= 0 && $0 <= maximum }) else {
                throw ScalarModularError.invalidInput("Invalid alpha sample")
            }
        }
        return VarDCTCoefficients(envelope: envelope, blocksX: bx, blocksY: by, strategies: strategies, dc: dc, ac: ac, alpha: alpha,
            quantFields: qf, sharpness: sharpness, xSlopes: xSlopes, bSlopes: bSlopes,
            globalScale: scale, quantDC: quantDC, dcExtraPrecision: precision,
            colourFactor: factor, baseX: baseX, baseB: baseB, dcX: dcX, dcB: dcB)
    }
}
