// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Decoded JPEG-bridged VarDCT frame (ISO/IEC 18181-1 §§6, 7, 8, 9.1–9.3, Annex C).
package struct JPEGBridgeFrame: Sendable {
    package struct ComponentSampling: Sendable, Equatable {
        package let hSamp: Int
        package let vSamp: Int
        package let blocksWide: Int
        package let blocksHigh: Int
    }

    package let width: Int
    package let height: Int
    package let coefficients: [[Int32]]
    package let quantisation: [[Int32]]
    package let iccProfile: Data?
    package let componentSampling: [ComponentSampling]

    package func resolve(_ metadata: JBRDBox) throws -> JBRDBox {
        guard metadata.components.count == coefficients.count,
              metadata.components.count == quantisation.count,
              metadata.components.count == componentSampling.count else {
            throw JPEGEntropyError.malformed
        }
        var resolved = metadata
        resolved.width = width
        resolved.height = height
        for ci in 0..<coefficients.count {
            let sampling = componentSampling[ci]
            resolved.components[ci].hSampFactor = sampling.hSamp
            resolved.components[ci].vSampFactor = sampling.vSamp
            resolved.components[ci].widthInBlocks = UInt32(sampling.blocksWide)
            resolved.components[ci].heightInBlocks = UInt32(sampling.blocksHigh)
            let qIdx = Int(resolved.components[ci].quantIdx)
            guard resolved.quant.indices.contains(qIdx) else {
                throw JPEGEntropyError.malformed
            }
            if resolved.quant[qIdx].values.isEmpty {
                resolved.quant[qIdx].values = quantisation[ci]
            } else {
                guard resolved.quant[qIdx].values == quantisation[ci] else {
                    throw JPEGEntropyError.malformed
                }
            }
        }
        guard resolved.quant.allSatisfy({ $0.values.count == 64 && $0.values.allSatisfy({ (1...65535).contains($0) }) }) else {
            throw JPEGEntropyError.malformed
        }
        return resolved
    }
}

/// Reads a JPEG-bridged VarDCT codestream per ISO/IEC 18181-1 §§6, 7, 8, 9.1–9.3, Annex C.
package enum JPEGBridgeFrameReader {
    private static let groupBlocks = 32
    private static let dcGroupBlocks = 256

    package static func read(
        _ data: Data,
        policy: JPEGBridgePolicy
    ) throws -> JPEGBridgeFrame {
        try policy.checkpoint()
        guard data.count >= 2, hasCodestreamSignature(data) else {
            throw JPEGEntropyError.malformed
        }

        let budget = try ScalarOperationBudget(
            retainedBytes: data.count,
            maximumWorkspaceBytes: policy.maximumMemoryBytes,
            maximumMemoryBytes: policy.maximumMemoryBytes,
            maximumDecodedBytes: policy.maximumCoefficientBytes,
            maximumCompressedBytes: max(1, data.count),
            deadline: policy.deadline
        )
        try budget.reserveWorkspace(
            ScalarOperationBudget.sum(
                ScalarOperationBudget.product(data.count, 4),
                16384
            )
        )

        let nesting = min(policy.maximumNestingDepth, 32)
        var reader = BitReader(
            data,
            startingAt: 16,
            deadline: policy.deadline,
            maximumNestingDepth: nesting,
            budget: budget
        )

        let sizeHeader = try SizeHeader.read(from: &reader)
        guard let width = Int(exactly: sizeHeader.xsize),
              let height = Int(exactly: sizeHeader.ysize),
              width > 0,
              height > 0 else {
            throw JPEGEntropyError.malformed
        }
        guard width <= 2048,
              height <= 2048,
              width <= policy.maximumDimension,
              height <= policy.maximumDimension,
              width <= policy.maximumPixels / height else {
            throw JPEGEntropyError.resourceLimit
        }

        let metadata = try ImageMetadata.read(from: &reader)
        let colour = metadata.colorEncoding
        guard !metadata.xybEncoded,
              !metadata.bitDepth.floatingPoint,
              metadata.bitDepth.bitsPerSample == 8,
              metadata.extraChannels.isEmpty,
              metadata.orientation == 1,
              metadata.preview == nil,
              metadata.animation == nil,
              metadata.intrinsicSize == nil,
              [.rgb, .grayscale].contains(colour.colorSpace) else {
            throw JPEGEntropyError.unsupported
        }

        // CustomTransformData: all_default must be true when xyb_encoded is false (ISO/IEC 18181-1 §6.1)
        guard try reader.readBit() else {
            throw JPEGEntropyError.unsupported
        }

        let iccProfile: Data?
        if colour.useICC {
            iccProfile = try ICCStream.decode(
                from: &reader,
                maximumBytes: policy.maximumICCBytes,
                checkpoint: policy.checkpoint
            )
            if let profile = iccProfile {
                guard profile.count >= 128,
                      profile.prefix(4).reduce(0, { ($0 << 8) | Int($1) }) == profile.count,
                      profile[36..<40] == Data("acsp".utf8),
                      profile[16..<20] == Data((colour.colorSpace == .grayscale ? "GRAY" : "RGB ").utf8) else {
                    throw JPEGEntropyError.malformed
                }
            }
        } else {
            iccProfile = nil
        }

        try reader.expectZeroPadding()
        let frame = try FrameHeader.read(
            from: &reader,
            context: FrameHeaderContext(
                xybEncoded: false,
                numExtraChannels: 0,
                haveAnimation: false,
                haveTimecodes: false
            )
        )
        guard frame.encoding == .varDCT,
              frame.frameType == .regular,
              frame.isLast,
              frame.colorTransform == .yCbCr || frame.colorTransform == .none,
              frame.upsampling == 1,
              frame.passes.numPasses == 1,
              !frame.customSizeOrOrigin,
              frame.blendingInfo.mode == .replace,
              frame.name.isEmpty,
              !frame.loopFilter.gab,
              frame.loopFilter.epfIters == 0,
              (frame.flags & ~FrameFlag.skipAdaptiveDcSmoothing.rawValue) == 0 else {
            throw JPEGEntropyError.unsupported
        }

        let subsampling = frame.colorTransform == .yCbCr
            ? frame.chromaSubsampling
            : YCbCrChromaSubsampling(y: 0, cb: 0, cr: 0)
        let isGray = (colour.colorSpace == .grayscale)
        if isGray && !subsampling.is444 {
            throw JPEGEntropyError.unsupported
        }

        let maxHShift = subsampling.maxHShift
        let maxVShift = subsampling.maxVShift
        let maxH = 1 << maxHShift
        let maxV = 1 << maxVShift
        let mcusWide = (width + 8 * maxH - 1) / (8 * maxH)
        let mcusHigh = (height + 8 * maxV - 1) / (8 * maxV)
        let fullBlocksX = mcusWide * maxH
        let fullBlocksY = mcusHigh * maxV
        guard fullBlocksX <= dcGroupBlocks, fullBlocksY <= dcGroupBlocks else {
            throw JPEGEntropyError.unsupported
        }

        let numComponents = isGray ? 1 : 3
        // Map JXL channel c in 0..<3 ([Cb/G, Y/R, Cr/B]) to JPEG component index:
        // For grayscale, only channel 1 (Y) maps to component 0.
        // For 3-component, channel 1 -> comp 0, channel 0 -> comp 1, channel 2 -> comp 2.
        let jxlToJpegComp: [Int?] = isGray
            ? [nil, 0, nil]
            : (frame.colorTransform == .none ? [0, 1, 2] : [1, 0, 2])

        var chBlocksWide = [Int](repeating: 0, count: 3)
        var chBlocksHigh = [Int](repeating: 0, count: 3)
        var chHShift = [Int](repeating: 0, count: 3)
        var chVShift = [Int](repeating: 0, count: 3)
        for c in 0..<3 {
            let hs = subsampling.hShift(c)
            let vs = subsampling.vShift(c)
            chHShift[c] = hs
            chVShift[c] = vs
            chBlocksWide[c] = fullBlocksX >> hs
            chBlocksHigh[c] = fullBlocksY >> vs
            guard chBlocksWide[c] > 0, chBlocksHigh[c] > 0 else {
                throw JPEGEntropyError.malformed
            }
        }

        var componentSampling = [JPEGBridgeFrame.ComponentSampling](
            repeating: .init(hSamp: 1, vSamp: 1, blocksWide: 0, blocksHigh: 0),
            count: numComponents
        )
        var totalCoeffCount = 0
        for c in 0..<3 {
            guard let ci = jxlToJpegComp[c] else { continue }
            let bw = chBlocksWide[c]
            let bh = chBlocksHigh[c]
            let hSamp = maxH >> chHShift[c]
            let vSamp = maxV >> chVShift[c]
            componentSampling[ci] = .init(hSamp: hSamp, vSamp: vSamp, blocksWide: bw, blocksHigh: bh)
            totalCoeffCount = try ScalarOperationBudget.sum(totalCoeffCount, bw * bh * 64)
        }

        let coeffBytes = try ScalarOperationBudget.product(totalCoeffCount, MemoryLayout<Int32>.stride)
        let admittedBytes = try ScalarOperationBudget.sum(
            ScalarOperationBudget.product(coeffBytes, 2),
            16384
        )
        guard coeffBytes <= policy.maximumCoefficientBytes,
              admittedBytes <= policy.maximumMemoryBytes else {
            throw JPEGEntropyError.resourceLimit
        }
        try budget.reservePixels(coeffBytes)
        try budget.reserveWorkspace(coeffBytes)

        let groupsX = (fullBlocksX + groupBlocks - 1) / groupBlocks
        let groupsY = (fullBlocksY + groupBlocks - 1) / groupBlocks
        let numGroups = groupsX * groupsY
        let singleSection = (numGroups == 1)
        let numEntries = TOC.numEntries(numGroups: numGroups, numDcGroups: 1, numPasses: 1)
        let toc = try TOC.read(from: &reader, numEntries: numEntries)
        let sectionStart = reader.position / 8

        var totalSectionBytes = 0
        for sz in toc.entrySizes {
            totalSectionBytes = try ScalarOperationBudget.sum(totalSectionBytes, Int(sz))
        }
        guard totalSectionBytes == data.count - sectionStart else {
            throw JPEGEntropyError.malformed
        }
        for i in toc.entrySizes.indices {
            guard let off = Int(exactly: toc.offsets[i]),
                  off <= totalSectionBytes,
                  Int(toc.entrySizes[i]) <= totalSectionBytes - off else {
                throw JPEGEntropyError.malformed
            }
        }

        func makeSectionReader(_ index: Int) throws -> BitReader {
            try policy.checkpoint()
            guard toc.entrySizes.indices.contains(index),
                  let off = Int(exactly: toc.offsets[index]) else {
                throw JPEGEntropyError.malformed
            }
            let len = Int(toc.entrySizes[index])
            let sub = data.subdata(in: (sectionStart + off)..<(sectionStart + off + len))
            return BitReader(
                sub,
                deadline: policy.deadline,
                maximumNestingDepth: nesting,
                budget: budget
            )
        }

        // --- 1. LfGlobal (ISO/IEC 18181-1 §9.3.1) ---
        var sec0 = try makeSectionReader(0)
        let lfDequantDefault = try sec0.readBit()
        var dcQuantFromLF = [Int32](repeating: 1, count: 3)
        if !lfDequantDefault {
            for c in 0..<3 {
                let rawHalf = UInt16(try sec0.read(bits: 16))
                let unscaled = halfToFloat(rawHalf)
                guard unscaled.isFinite, unscaled > 0 else {
                    throw JPEGEntropyError.malformed
                }
                let q = (unscaled * (2040.0 / 128.0)).rounded()
                guard q >= 1, q <= 65535 else {
                    throw JPEGEntropyError.malformed
                }
                dcQuantFromLF[c] = Int32(q)
            }
        }

        let globalScale = try sec0.readU32((
            .offset(constant: 1, extraBits: 11),
            .offset(constant: 2049, extraBits: 11),
            .offset(constant: 4097, extraBits: 12),
            .offset(constant: 8193, extraBits: 16)
        ))
        let quantLF = try sec0.readU32((
            .literal(16),
            .offset(constant: 1, extraBits: 5),
            .offset(constant: 1, extraBits: 8),
            .offset(constant: 1, extraBits: 16)
        ))
        guard globalScale > 0, quantLF > 0 else {
            throw JPEGEntropyError.malformed
        }

        let hfBlockCtx = try BridgeHFBlockContext.read(from: &sec0, policy: policy)

        let cflDefault = try sec0.readBit()
        var cflColorFactor: UInt32 = 84
        var cflBaseX: Float = 0.0
        var cflBaseB: Float = 1.0
        var cflYtoXLF: Int32 = 0
        var cflYtoBLF: Int32 = 0
        if !cflDefault {
            let colorFactor = try sec0.readU32((
                .literal(84),
                .literal(256),
                .offset(constant: 2, extraBits: 8),
                .offset(constant: 258, extraBits: 16)
            ))
            let baseX = halfToFloat(UInt16(try sec0.read(bits: 16)))
            let baseB = halfToFloat(UInt16(try sec0.read(bits: 16)))
            let ytoxLF = Int32(try sec0.read(bits: 8)) - 128
            let ytobLF = Int32(try sec0.read(bits: 8)) - 128
            guard colorFactor > 0, baseX.isFinite, baseB.isFinite else {
                throw JPEGEntropyError.malformed
            }
            cflColorFactor = colorFactor
            cflBaseX = baseX
            cflBaseB = baseB
            cflYtoXLF = ytoxLF
            cflYtoBLF = ytobLF
        }

        let hasGlobalTree = try sec0.readBit()
        let globalEntropy: ModularFrameDecoder.EntropyBundle?
        if hasGlobalTree {
            let treePixels = max(width * height, fullBlocksX * fullBlocksY * 3)
            let raw = try ScalarModularDecoder.readTreeAndCodebook(from: &sec0, pixelCount: treePixels)
            try budget.reserveWorkspace(ScalarOperationBudget.product(raw.2.ansCounts.count, 64 * 1024))
            globalEntropy = (raw.0, raw.1, raw.2)
        } else {
            globalEntropy = nil
        }

        if !singleSection {
            try sec0.expectZeroPadding()
            guard sec0.isExhausted else {
                throw JPEGEntropyError.malformed
            }
        }

        // --- 2. LfGroup[0] (ISO/IEC 18181-1 §9.3.2) ---
        var lfGroupReader = singleSection ? sec0 : try makeSectionReader(1)
        let extraPrecision = try lfGroupReader.read(bits: 2)
        guard extraPrecision == 0 else {
            throw JPEGEntropyError.unsupported
        }

        // DC Modular substream in stream order [0: Y(1), 1: X/Cb(0), 2: B/Cr(2)]
        let dcStreamPlanes = try decodeBridgeModularSubstream(
            dimensions: [
                (chBlocksWide[1], chBlocksHigh[1], 3 + chHShift[1], 3 + chVShift[1]),
                (chBlocksWide[0], chBlocksHigh[0], 3 + chHShift[0], 3 + chVShift[0]),
                (chBlocksWide[2], chBlocksHigh[2], 3 + chHShift[2], 3 + chVShift[2]),
            ],
            groupId: 1,
            globalEntropy: globalEntropy,
            from: &lfGroupReader,
            budget: budget,
            policy: policy
        )
        let dcPlanes = [
            dcStreamPlanes[1].pixels,
            dcStreamPlanes[0].pixels,
            dcStreamPlanes[2].pixels,
        ]

        // HfMetadata Modular substream
        let regionBlocks = fullBlocksX * fullBlocksY
        let nbBlocksBits = Self.ceilLog2(regionBlocks)
        let nbBlocks: Int
        if nbBlocksBits > 0 {
            nbBlocks = Int(try lfGroupReader.read(bits: nbBlocksBits)) + 1
        } else {
            nbBlocks = 1
        }
        guard nbBlocks >= 1, nbBlocks <= regionBlocks else {
            throw JPEGEntropyError.malformed
        }

        let tilesX = (fullBlocksX + 7) / 8
        let tilesY = (fullBlocksY + 7) / 8
        let metaPlanes = try decodeBridgeModularSubstream(
            dimensions: [
                (tilesX, tilesY, 0, 0),
                (tilesX, tilesY, 0, 0),
                (nbBlocks, 2, 0, 0),
                (fullBlocksX, fullBlocksY, 0, 0),
            ],
            groupId: 3,
            globalEntropy: globalEntropy,
            from: &lfGroupReader,
            budget: budget,
            policy: policy
        )

        // Verify all blocks use DCT8 (strategy 0) and unit quantisation field
        let blockInfo = metaPlanes[2].pixels
        guard nbBlocks == regionBlocks else {
            throw JPEGEntropyError.unsupported
        }
        for i in 0..<nbBlocks {
            guard blockInfo[i] == 0 else {
                throw JPEGEntropyError.unsupported
            }
            let rawQF = blockInfo[nbBlocks + i] + 1
            guard rawQF == 1 else {
                throw JPEGEntropyError.unsupported
            }
        }

        if singleSection {
            sec0 = lfGroupReader
        } else {
            try lfGroupReader.expectZeroPadding()
            guard lfGroupReader.isExhausted else {
                throw JPEGEntropyError.malformed
            }
        }

        // --- 3. HfGlobal (ISO/IEC 18181-1 §9.3.3 & Annex C) ---
        var hfGlobalReader = singleSection ? sec0 : try makeSectionReader(2)
        let dequantAllDefault = try hfGlobalReader.readBit()
        guard !dequantAllDefault else {
            throw JPEGEntropyError.unsupported
        }

        let dct8Mode = try hfGlobalReader.read(bits: 3)
        guard dct8Mode == 7 else {
            throw JPEGEntropyError.unsupported
        }
        let denomRaw = UInt16(try hfGlobalReader.read(bits: 16))
        let denom = halfToFloat(denomRaw)
        guard denom.isFinite, denom > 0 else {
            throw JPEGEntropyError.malformed
        }

        let rawQuantPlanes = try decodeBridgeModularSubstream(
            dimensions: [(8, 8, 0, 0), (8, 8, 0, 0), (8, 8, 0, 0)],
            groupId: 4,
            globalEntropy: globalEntropy,
            from: &hfGlobalReader,
            budget: budget,
            policy: policy
        )
        guard rawQuantPlanes.count == 3,
              rawQuantPlanes.allSatisfy({ $0.pixels.count == 64 }) else {
            throw JPEGEntropyError.malformed
        }

        for _ in 1..<17 {
            let mode = try hfGlobalReader.read(bits: 3)
            guard mode == 0 else {
                throw JPEGEntropyError.unsupported
            }
        }

        var quantisation = [[Int32]](repeating: [Int32](repeating: 1, count: 64), count: numComponents)
        for c in 0..<3 {
            guard let ci = jxlToJpegComp[c] else { continue }
            let plane = rawQuantPlanes[c].pixels
            var qTable = [Int32](repeating: 1, count: 64)
            for y in 0..<8 {
                for x in 0..<8 {
                    let qVal = plane[y * 8 + x]
                    let scaled = (Float(qVal) * denom * 2040.0).rounded()
                    guard scaled >= 1, scaled <= 65535 else {
                        throw JPEGEntropyError.malformed
                    }
                    qTable[x * 8 + y] = Int32(scaled)
                }
            }
            if !lfDequantDefault && qTable[0] <= 2048 {
                qTable[0] = dcQuantFromLF[c]
            }
            quantisation[ci] = qTable
        }

        let presetBits = Self.ceilLog2(numGroups)
        let numHfPresets: Int
        if presetBits > 0 {
            numHfPresets = Int(try hfGlobalReader.read(bits: presetBits)) + 1
        } else {
            numHfPresets = 1
        }
        guard numHfPresets >= 1, numHfPresets <= numGroups else {
            throw JPEGEntropyError.malformed
        }

        let usedOrders = try hfGlobalReader.readU32((
            .literal(0x5F),
            .literal(0x13),
            .literal(0),
            .bits(13)
        ))
        let passOrders = try VarDCTOrders.decodeOrders(
            usedOrders: usedOrders,
            from: &hfGlobalReader,
            budget: budget
        )

        let totalACContexts = try ScalarOperationBudget.product(
            VarDCTEntropy.contextsPerBlockCluster,
            ScalarOperationBudget.product(numHfPresets, hfBlockCtx.numBlockClusters)
        )
        let acEntropyHeader = try EntropySectionHeader.read(
            from: &hfGlobalReader,
            numContexts: totalACContexts,
            maximumContexts: max(4096, min(524288, totalACContexts))
        )
        let acCodebook = try MultiClusterCodebook.read(from: &hfGlobalReader, header: acEntropyHeader)
        try budget.reserveWorkspace(ScalarOperationBudget.product(acCodebook.ansCounts.count, 64 * 1024))

        if singleSection {
            sec0 = hfGlobalReader
        } else {
            try hfGlobalReader.expectZeroPadding()
            guard hfGlobalReader.isExhausted else {
                throw JPEGEntropyError.malformed
            }
        }

        // --- 4. HfPass[0..<numGroups] (ISO/IEC 18181-1 §9.3.4) ---
        var coefficients: [[Int32]] = []
        coefficients.reserveCapacity(numComponents)
        for ci in 0..<numComponents {
            let samp = componentSampling[ci]
            coefficients.append([Int32](repeating: 0, count: samp.blocksWide * samp.blocksHigh * 64))
        }

        var blockScratch = [Int32](repeating: 0, count: 64)
        var lumaScratch = [Int32](repeating: 0, count: 64)
        let hfPassPresetBits = Self.ceilLog2(numHfPresets)

        for groupIdx in 0..<numGroups {
            try policy.checkpoint()
            let gx = groupIdx % groupsX
            let gy = groupIdx / groupsX
            let bx0 = gx * groupBlocks
            let by0 = gy * groupBlocks
            let gw = min(groupBlocks, fullBlocksX - bx0)
            let gh = min(groupBlocks, fullBlocksY - by0)

            var passReader = singleSection ? sec0 : try makeSectionReader(3 + groupIdx)
            let hfPreset: Int
            if hfPassPresetBits > 0 {
                hfPreset = Int(try passReader.read(bits: hfPassPresetBits))
            } else {
                hfPreset = 0
            }
            guard hfPreset >= 0, hfPreset < numHfPresets else {
                throw JPEGEntropyError.malformed
            }

            let presetCtxOffset = hfPreset * VarDCTEntropy.contextsPerBlockCluster * hfBlockCtx.numBlockClusters
            var acStream = TokenStreamReader(header: acEntropyHeader, codebook: acCodebook)

            var nzGrids: [[Int32]] = []
            var subWidths: [Int] = []
            for c in 0..<3 {
                let hs = chHShift[c]
                let vs = chVShift[c]
                let sw = (gw + (1 << hs) - 1) >> hs
                let sh = (gh + (1 << vs) - 1) >> vs
                subWidths.append(sw)
                nzGrids.append([Int32](repeating: 0, count: sw * sh))
            }

            for ly in 0..<gh {
                if (ly & 7) == 0 { try policy.checkpoint() }
                let by = by0 + ly
                for lx in 0..<gw {
                    let bx = bx0 + lx
                    for c in [1, 0, 2] {
                        let hs = chHShift[c]
                        let vs = chVShift[c]
                        if (bx & ((1 << hs) - 1)) != 0 || (by & ((1 << vs) - 1)) != 0 {
                            continue
                        }
                        let cbx = bx >> hs
                        let cby = by >> vs
                        let clx = lx >> hs
                        let cly = ly >> vs
                        let sw = subWidths[c]
                        let predictedNZ = nzGrids[c].withUnsafeBufferPointer { ptr in
                            VarDCTEntropy.predictedNonZeros(x: clx, y: cly, width: sw, grid: ptr)
                        }

                        let dcX = dcPlanes[0][(by >> chVShift[0]) * chBlocksWide[0] + (bx >> chHShift[0])]
                        let dcY = dcPlanes[1][(by >> chVShift[1]) * chBlocksWide[1] + (bx >> chHShift[1])]
                        let dcB = dcPlanes[2][(by >> chVShift[2]) * chBlocksWide[2] + (bx >> chHShift[2])]

                        let blockCluster = hfBlockCtx.cluster(
                            channel: c,
                            orderBucket: 0,
                            quant: 1,
                            dcX: dcX,
                            dcY: dcY,
                            dcB: dcB
                        )
                        let nzCtx = presetCtxOffset + VarDCTEntropy.nonZeroContext(
                            predicted: predictedNZ,
                            blockContext: blockCluster,
                            numBlockClusters: hfBlockCtx.numBlockClusters
                        )
                        let nonZeros = Int(try acStream.readToken(context: nzCtx, from: &passReader))
                        guard nonZeros >= 0, nonZeros <= 63 else {
                            throw JPEGEntropyError.malformed
                        }
                        nzGrids[c][cly * sw + clx] = Int32(nonZeros)

                        let blockIndex = cby * chBlocksWide[c] + cbx
                        var dcVal = dcPlanes[c][blockIndex]
                        if c != 1 && subsampling.is444 {
                            let lfFactor = (c == 0) ? cflYtoXLF : cflYtoBLF
                            let baseCorr = (c == 0) ? cflBaseX : cflBaseB
                            if lfFactor != 0 || baseCorr != 0 {
                                let scale = baseCorr + Float(lfFactor) / Float(cflColorFactor)
                                let dcCorr = Int32((Float(dcY) * scale).rounded(.toNearestOrEven))
                                let (corrDC, corrOverflow) = dcVal.addingReportingOverflow(dcCorr)
                                guard !corrOverflow else { throw JPEGEntropyError.malformed }
                                dcVal = corrDC
                            }
                        }
                        if frame.colorTransform == .none, let ci = jxlToJpegComp[c] {
                            let qDC = quantisation[ci][0]
                            guard qDC > 0 else { throw JPEGEntropyError.malformed }
                            let dcOffset = Int32(1024) / qDC
                            let (unshifted, overflow) = dcVal.subtractingReportingOverflow(dcOffset)
                            guard !overflow else { throw JPEGEntropyError.malformed }
                            dcVal = unshifted
                        }

                        for k in 1..<64 {
                            blockScratch[k] = 0
                        }
                        blockScratch[0] = dcVal

                        if nonZeros > 0 {
                            let order = passOrders[0][c]
                            guard order.count == 64 else {
                                throw JPEGEntropyError.malformed
                            }
                            var remainingNZ = nonZeros
                            var prev = (nonZeros > 4) ? 0 : 1
                            for k in 1..<64 {
                                if remainingNZ == 0 { break }
                                let zCtx = presetCtxOffset + VarDCTEntropy.zeroDensityContext(
                                    nonZerosLeft: remainingNZ,
                                    k: k,
                                    log2CoveredBlocks: 0,
                                    prev: prev,
                                    blockContext: blockCluster,
                                    numBlockClusters: hfBlockCtx.numBlockClusters
                                )
                                let rawTok = try acStream.readToken(context: zCtx, from: &passReader)
                                let coeff = ZigZag.unpack(rawTok)
                                blockScratch[order[k]] = coeff
                                if coeff != 0 {
                                    remainingNZ -= 1
                                    prev = 1
                                } else {
                                    prev = 0
                                }
                            }
                            guard remainingNZ == 0 else {
                                throw JPEGEntropyError.malformed
                            }
                        }

                        if c == 1 {
                            for k in 0..<64 {
                                lumaScratch[k] = blockScratch[k]
                            }
                        } else if subsampling.is444 {
                            let tileIdx = (by / 8) * tilesX + (bx / 8)
                            let mapVal = (c == 0)
                                ? metaPlanes[0].pixels[tileIdx]
                                : metaPlanes[1].pixels[tileIdx]
                            let baseCorr = (c == 0) ? cflBaseX : cflBaseB
                            if mapVal != 0 || baseCorr != 0 {
                                let scale = baseCorr + Float(mapVal) / Float(cflColorFactor)
                                for k in 1..<64 {
                                    let corr = Int32((Float(lumaScratch[k]) * scale).rounded(.toNearestOrEven))
                                    let (summed, overflow) = blockScratch[k].addingReportingOverflow(corr)
                                    guard !overflow else { throw JPEGEntropyError.malformed }
                                    blockScratch[k] = summed
                                }
                            }
                        }

                        if let ci = jxlToJpegComp[c] {
                            let base = blockIndex * 64
                            for y in 0..<8 {
                                for x in 0..<8 {
                                    coefficients[ci][base + x * 8 + y] = blockScratch[y * 8 + x]
                                }
                            }
                        }
                    }
                }
            }

            try acStream.finish(from: &passReader)
            try passReader.expectZeroPadding()
            guard passReader.isExhausted else {
                throw JPEGEntropyError.malformed
            }
        }

        try policy.checkpoint()
        return JPEGBridgeFrame(
            width: width,
            height: height,
            coefficients: coefficients,
            quantisation: quantisation,
            iccProfile: iccProfile,
            componentSampling: componentSampling
        )
    }

    // MARK: - Private Helpers

    @inline(__always)
    private static func ceilLog2(_ n: Int) -> Int {
        guard n > 1 else { return 0 }
        return Int.bitWidth - (n - 1).leadingZeroBitCount
    }

    private static func decodeBridgeModularSubstream(
        dimensions: [(width: Int, height: Int, hshift: Int, vshift: Int)],
        groupId: Int32,
        globalEntropy: ModularFrameDecoder.EntropyBundle?,
        from reader: inout BitReader,
        budget: ScalarOperationBudget,
        policy: JPEGBridgePolicy
    ) throws -> [ModularChannel] {
        try policy.checkpoint()
        let groupHeader = try GroupHeader.read(from: &reader)
        let pixelCount = dimensions.reduce(0) { $0 + $1.width * $1.height }
        let entropy: ModularFrameDecoder.EntropyBundle
        if groupHeader.useGlobalTree {
            guard let globalEntropy else {
                throw JPEGEntropyError.malformed
            }
            entropy = globalEntropy
        } else {
            let raw = try ScalarModularDecoder.readTreeAndCodebook(from: &reader, pixelCount: pixelCount)
            try budget.reserveWorkspace(ScalarOperationBudget.product(raw.2.ansCounts.count, 64 * 1024))
            entropy = (raw.0, raw.1, raw.2)
        }

        try ModularImage.admitDescriptors(dimensions.count, budget: budget)
        var subImage = try ModularImage(
            channels: dimensions.map {
                try ModularChannel(width: $0.width, height: $0.height, hshift: $0.hshift, vshift: $0.vshift)
            }
        )
        let localTransforms = try metaApplyTransforms(
            image: &subImage,
            transforms: groupHeader.transforms,
            budget: budget
        )
        let maxW = subImage.channels.map(\.width).max() ?? 0
        var stream = TokenStreamReader(
            header: entropy.header,
            codebook: entropy.codebook,
            distanceMultiplier: maxW
        )
        for i in subImage.channels.indices {
            try policy.checkpoint()
            try subImage.channels[i].allocatePixels(budget: budget)
            if subImage.channels[i].sampleCount > 0 {
                let chW = subImage.channels[i].width
                let chH = subImage.channels[i].height
                try budget.reserveWorkspace(
                    ScalarOperationBudget.sum(
                        ScalarOperationBudget.product(chW + 2, 192),
                        1024
                    )
                )
                try subImage.channels[i].pixels.withUnsafeMutableBufferPointer { ptr in
                    var target = ptr
                    try decodeModularChannel(
                        width: chW,
                        height: chH,
                        staticChannel: Int32(i),
                        groupId: groupId,
                        tree: entropy.tree,
                        stream: &stream,
                        from: &reader,
                        wpHeader: groupHeader.wpHeader,
                        sampleMaximum: nil,
                        out: &target
                    )
                }
            }
        }
        try stream.finish(from: &reader)
        if !localTransforms.isEmpty {
            try applyInverseTransforms(
                image: &subImage,
                transforms: localTransforms,
                bitDepth: 8,
                budget: budget
            )
        }
        guard subImage.channels.count == dimensions.count else {
            throw JPEGEntropyError.malformed
        }
        return subImage.channels
    }
}

private struct BridgeHFBlockContext: Sendable {
    let lfThresholds: [[Int32]]
    let qfThresholds: [Int32]
    let blockCtxMap: [Int]
    let numBlockClusters: Int

    static func read(from reader: inout BitReader, policy: JPEGBridgePolicy) throws -> Self {
        try policy.checkpoint()
        let isDefault = try reader.readBit()
        if isDefault {
            return Self(
                lfThresholds: [[], [], []],
                qfThresholds: [],
                blockCtxMap: VarDCTEntropy.defaultBlockCtxMap,
                numBlockClusters: VarDCTEntropy.defaultNumBlockClusters
            )
        }

        var lfThresholds: [[Int32]] = [[], [], []]
        var numLFContexts = 1
        for i in 0..<3 {
            let count = Int(try reader.read(bits: 4))
            var thresholds: [Int32] = []
            thresholds.reserveCapacity(count)
            for _ in 0..<count {
                let raw = try reader.readU32((
                    .bits(4),
                    .offset(constant: 16, extraBits: 8),
                    .offset(constant: 272, extraBits: 16),
                    .offset(constant: 65808, extraBits: 32)
                ))
                thresholds.append(ZigZag.unpack(raw))
            }
            lfThresholds[i] = thresholds
            numLFContexts *= (count + 1)
        }

        let qfCount = Int(try reader.read(bits: 4))
        var qfThresholds: [Int32] = []
        qfThresholds.reserveCapacity(qfCount)
        for _ in 0..<qfCount {
            let raw = try reader.readU32((
                .bits(2),
                .offset(constant: 4, extraBits: 3),
                .offset(constant: 12, extraBits: 5),
                .offset(constant: 44, extraBits: 8)
            ))
            qfThresholds.append(Int32(raw) + 1)
        }

        let bsize = numLFContexts * (qfCount + 1) * 39
        guard bsize <= 39 * 64 else {
            throw JPEGEntropyError.malformed
        }
        let cmap = try ContextMap.read(numContexts: bsize, from: &reader)
        guard cmap.numClusters >= 1, cmap.numClusters <= 16 else {
            throw JPEGEntropyError.malformed
        }
        return Self(
            lfThresholds: lfThresholds,
            qfThresholds: qfThresholds,
            blockCtxMap: cmap.map.map { Int($0) },
            numBlockClusters: cmap.numClusters
        )
    }

    @inline(__always)
    func cluster(
        channel: Int,
        orderBucket: Int,
        quant: Int32,
        dcX: Int32,
        dcY: Int32,
        dcB: Int32
    ) -> Int {
        let cIdx = (channel == 1) ? 0 : (channel == 0 ? 1 : 2)
        var idx = cIdx * 13 + orderBucket
        if !qfThresholds.isEmpty {
            var qCtx = 0
            for t in qfThresholds where quant > t { qCtx += 1 }
            idx = idx * (qfThresholds.count + 1) + qCtx
        }
        if !lfThresholds[0].isEmpty || !lfThresholds[1].isEmpty || !lfThresholds[2].isEmpty {
            let dcs = [dcX, dcY, dcB]
            for i in 0..<3 {
                var lCtx = 0
                for t in lfThresholds[i] where dcs[i] > t { lCtx += 1 }
                idx = idx * (lfThresholds[i].count + 1) + lCtx
            }
        }
        return blockCtxMap[idx]
    }
}
