// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Parsed and entropy-decoded VarDCT frame coefficients, strategy map, quantisation fields,
/// and optional Modular extra channel per ISO/IEC 18181-1 §9.3.
package struct VarDCTCoefficients: Sendable {
    package let envelope: VarDCTFrameEnvelope
    package let width: Int
    package let height: Int
    package let blocksX: Int
    package let blocksY: Int
    package let globalScale: UInt32
    package let quantLF: UInt32
    package let lfDequant: [Float]
    package let extraPrecision: Int
    package let colorFactor: UInt32
    package let baseCorrelationX: Float
    package let baseCorrelationB: Float
    package let ytoxLF: Int32
    package let ytobLF: Int32
    package let dc: [[Int32]]
    package let cflX: [Int32]
    package let cflB: [Int32]
    package let tilesX: Int
    package let tilesY: Int
    package let transforms: [VarDCTStrategyMap.Transform]
    package let strategies: [Int32]
    package let quantField: [UInt32]
    package let sharpnessField: [Int32]
    package let ac: [[Int32]]
    package let alpha: [Int32]?

    package static func read(_ envelope: VarDCTFrameEnvelope) throws -> Self {
        let budget = envelope.budget
        try budget.checkpoint()

        // Supported VarDCT profile: regular frame, 1 pass, at most 1 alpha extra channel,
        // no patches (bit 1 = 2), splines (bit 4 = 16), or noise (bit 0 = 1).
        guard envelope.frame.encoding == .varDCT,
              envelope.frame.passes.numPasses == 1,
              envelope.metadata.extraChannels.count <= 1,
              (envelope.frame.flags & (1 | 2 | 16)) == 0,
              !envelope.frame.loopFilter.hasCustomParameters else {
            throw ScalarModularError.unsupportedProfile
        }
        if let extra = envelope.metadata.extraChannels.first {
            guard extra.type == .alpha,
                  extra.dimShift == 0,
                  extra.bitDepth.bitsPerSample == envelope.metadata.bitDepth.bitsPerSample,
                  !extra.bitDepth.floatingPoint else {
                throw ScalarModularError.unsupportedProfile
            }
        }

        let width = envelope.width
        let height = envelope.height
        let blocksX = (width + 7) / 8
        let blocksY = (height + 7) / 8
        let totalBlocks = try ScalarOperationBudget.product(blocksX, blocksY)
        let groupsX = envelope.groupsX
        let groupsY = envelope.groupsY
        let numGroups = try ScalarOperationBudget.product(groupsX, groupsY)
        let dcGroupsX = envelope.dcGroupsX
        let dcGroupsY = envelope.dcGroupsY
        let numDCGroups = try ScalarOperationBudget.product(dcGroupsX, dcGroupsY)
        let tilesX = (blocksX + 7) / 8
        let tilesY = (blocksY + 7) / 8
        let totalTiles = try ScalarOperationBudget.product(tilesX, tilesY)
        let groupDim = envelope.groupDimension
        let acGroupBlocks = max(1, groupDim / 8)
        let dcGroupBlocks = groupDim
        let hasAlpha = !envelope.metadata.extraChannels.isEmpty
        let bitsPerSample = Int(envelope.metadata.bitDepth.bitsPerSample)
        let sampleMax = (Int32(1) << bitsPerSample) - 1

        // Reserve coefficient and field workspace upfront
        let dcWorkspace = try ScalarOperationBudget.product(totalBlocks, 3 * MemoryLayout<Int32>.size)
        let fieldWorkspace = try ScalarOperationBudget.product(totalBlocks, 3 * MemoryLayout<Int32>.size)
        let acBaseWorkspace = try ScalarOperationBudget.product(totalBlocks, 64 * 3 * MemoryLayout<Int32>.size)
        try budget.reserveWorkspace(
            ScalarOperationBudget.sum(dcWorkspace, ScalarOperationBudget.sum(fieldWorkspace, acBaseWorkspace))
        )

        let singleSection = (numGroups == 1 && envelope.frame.passes.numPasses == 1)
        var sec0Reader = try envelope.section(0)

        // --- 1. LfGlobal (ISO/IEC 18181-1 §9.3.1) ---
        let lfDequantDefault = try sec0Reader.readBit()
        var lfDequant: [Float] = [1.0 / 4096.0, 1.0 / 512.0, 1.0 / 256.0]
        if !lfDequantDefault {
            let mx = halfToFloat(UInt16(try sec0Reader.read(bits: 16))) / 4096.0
            let my = halfToFloat(UInt16(try sec0Reader.read(bits: 16))) / 512.0
            let mb = halfToFloat(UInt16(try sec0Reader.read(bits: 16))) / 256.0
            guard mx.isFinite, mx > 0, my.isFinite, my > 0, mb.isFinite, mb > 0 else {
                throw ScalarModularError.invalidInput("Invalid LfChannelDequantization in VarDCT LfGlobal")
            }
            lfDequant = [mx, my, mb]
        }

        let globalScale = try sec0Reader.readU32((
            .offset(constant: 1, extraBits: 11),
            .offset(constant: 2049, extraBits: 11),
            .offset(constant: 4097, extraBits: 12),
            .offset(constant: 8193, extraBits: 16)
        ))
        let quantLF = try sec0Reader.readU32((
            .literal(16),
            .offset(constant: 1, extraBits: 5),
            .offset(constant: 1, extraBits: 8),
            .offset(constant: 1, extraBits: 16)
        ))
        guard globalScale > 0, quantLF > 0 else {
            throw ScalarModularError.invalidInput("Invalid Quantizer in VarDCT LfGlobal")
        }

        let hfBlockCtx = try HFBlockContextDescriptor.read(from: &sec0Reader, budget: budget)

        let cflDefault = try sec0Reader.readBit()
        var colorFactor: UInt32 = 84
        var baseCorrelationX: Float = 0.0
        var baseCorrelationB: Float = 1.0
        var ytoxLF: Int32 = 0
        var ytobLF: Int32 = 0
        if !cflDefault {
            colorFactor = try sec0Reader.readU32((
                .literal(84),
                .literal(256),
                .offset(constant: 2, extraBits: 8),
                .offset(constant: 258, extraBits: 16)
            ))
            baseCorrelationX = halfToFloat(UInt16(try sec0Reader.read(bits: 16)))
            baseCorrelationB = halfToFloat(UInt16(try sec0Reader.read(bits: 16)))
            let xBits = try sec0Reader.read(bits: 8)
            let bBits = try sec0Reader.read(bits: 8)
            guard colorFactor > 0,
                  baseCorrelationX.isFinite,
                  baseCorrelationB.isFinite else {
                throw ScalarModularError.invalidInput("Invalid LfChannelCorrelation in VarDCT LfGlobal")
            }
            ytoxLF = Int32(xBits) - 128
            ytobLF = Int32(bBits) - 128
        }

        let hasGlobalTree = try sec0Reader.readBit()
        let globalEntropy: ModularFrameDecoder.EntropyBundle?
        if hasGlobalTree {
            let treePixels = max(width * height, totalBlocks * 3)
            let raw = try ScalarModularDecoder.readTreeAndCodebook(from: &sec0Reader, pixelCount: treePixels)
            try budget.reserveWorkspace(ScalarOperationBudget.product(raw.2.ansCounts.count, 64 * 1024))
            globalEntropy = (raw.0, raw.1, raw.2)
        } else {
            globalEntropy = nil
        }

        // Optional Global Modular extra-channel setup (for straight alpha)
        var extraImage: ModularImage? = nil
        var extraGlobalTransforms: [ModularTransform] = []
        var extraFirstNonGlobal = 0

        if hasAlpha {
            let extraHeader = try GroupHeader.read(from: &sec0Reader)
            try ModularImage.admitDescriptors(1, budget: budget)
            var img = try ModularImage(
                channels: [try ModularChannel(width: width, height: height)]
            )
            let gTransforms = try metaApplyTransforms(
                image: &img,
                transforms: extraHeader.transforms,
                budget: budget
            )
            for i in img.channels.indices {
                try img.channels[i].allocatePixels(budget: budget)
            }
            var firstNonGlobal = img.channels.count
            for i in img.nbMetaChannels..<img.channels.count {
                let ch = img.channels[i]
                if ch.width > groupDim || ch.height > groupDim {
                    firstNonGlobal = i
                    break
                }
            }
            let globalIndices = Array(0..<firstNonGlobal)
            let globalPixels = globalIndices.reduce(0) { $0 + img.channels[$1].sampleCount }
            let entropy = try selectModularEntropy(
                header: extraHeader,
                globalEntropy: globalEntropy,
                from: &sec0Reader,
                pixelCount: max(width * height, globalPixels),
                budget: budget
            )
            let maxW = globalIndices.map { img.channels[$0].width }.max() ?? 0
            var stream = TokenStreamReader(
                header: entropy.header,
                codebook: entropy.codebook,
                distanceMultiplier: maxW
            )
            for (staticIdx, chIdx) in globalIndices.enumerated() {
                try decodeModularChannelArray(
                    channel: &img.channels[chIdx],
                    staticChannel: Int32(staticIdx),
                    groupId: 0,
                    tree: entropy.tree,
                    stream: &stream,
                    from: &sec0Reader,
                    wpHeader: extraHeader.wpHeader,
                    budget: budget
                )
            }
            try stream.finish(from: &sec0Reader)
            extraImage = img
            extraGlobalTransforms = gTransforms
            extraFirstNonGlobal = firstNonGlobal
        }

        if !singleSection {
            try sec0Reader.expectZeroPadding()
            guard sec0Reader.isExhausted else {
                throw ScalarModularError.invalidInput("Unexpected trailing bytes in VarDCT LfGlobal section")
            }
        }

        // --- 2. LfGroup sections (ISO/IEC 18181-1 §9.3.2) ---
        var dc = [
            [Int32](repeating: 0, count: totalBlocks),
            [Int32](repeating: 0, count: totalBlocks),
            [Int32](repeating: 0, count: totalBlocks),
        ]
        var cflX = [Int32](repeating: 0, count: totalTiles)
        var cflB = [Int32](repeating: 0, count: totalTiles)
        var allTransforms: [VarDCTStrategyMap.Transform] = []
        var strategies = [Int32](repeating: 0, count: totalBlocks)
        var quantField = [UInt32](repeating: 1, count: totalBlocks)
        var sharpnessField = [Int32](repeating: 0, count: totalBlocks)
        var totalACCoefficients = 0
        var frameExtraPrecision: Int? = nil

        for dcGroup in 0..<numDCGroups {
            try budget.checkpoint()
            let dcx = dcGroup % dcGroupsX
            let dcy = dcGroup / dcGroupsX
            let bx0 = dcx * dcGroupBlocks
            let by0 = dcy * dcGroupBlocks
            let regionW = min(dcGroupBlocks, blocksX - bx0)
            let regionH = min(dcGroupBlocks, blocksY - by0)
            let regionBlocks = regionW * regionH

            var groupReader = singleSection ? sec0Reader : try envelope.section(1 + dcGroup)

            let epBits = try groupReader.read(bits: 2)
            let ep = Int(epBits)
            if let existingEP = frameExtraPrecision, existingEP != ep {
                throw ScalarModularError.unsupportedProfile
            }
            frameExtraPrecision = ep

            // 2a. 3-channel DC Modular sub-stream (stream order: [0: Y, 1: X, 2: B])
            let dcPlanes = try decodeModularSubstream(
                dimensions: [(regionW, regionH, 3, 3), (regionW, regionH, 3, 3), (regionW, regionH, 3, 3)],
                groupId: Int32(1 + dcGroup),
                globalEntropy: globalEntropy,
                bitDepth: bitsPerSample,
                from: &groupReader,
                budget: budget
            )
            let streamToXYB = [1, 0, 2]
            for s in 0..<3 {
                let dstC = streamToXYB[s]
                let plane = dcPlanes[s].pixels
                for ry in 0..<regionH {
                    let srcRow = ry * regionW
                    let dstRow = (by0 + ry) * blocksX + bx0
                    for rx in 0..<regionW {
                        dc[dstC][dstRow + rx] = plane[srcRow + rx]
                    }
                }
            }

            // 2b. Optional extra-channel LfGroup Modular sub-stream (for channels with min(hshift, vshift) >= 3)
            if var img = extraImage {
                let slices = groupSlicesForExtra(
                    image: img,
                    firstNonGlobal: extraFirstNonGlobal,
                    gx: dcx,
                    gy: dcy,
                    baseDim: dcGroupBlocks * 8,
                    isDCGroup: true
                )
                if !slices.isEmpty {
                    let planes = try decodeModularSubstream(
                        dimensions: slices.map { ($0.width, $0.height, $0.hshift, $0.vshift) },
                        groupId: Int32(1 + numDCGroups + dcGroup),
                        globalEntropy: globalEntropy,
                        bitDepth: bitsPerSample,
                        from: &groupReader,
                        budget: budget
                    )
                    for (i, slice) in slices.enumerated() {
                        copySliceIntoChannel(planes[i], slice: slice, into: &img.channels[slice.channelIndex])
                    }
                    extraImage = img
                }
            }

            // 2c. HfMetadata Modular sub-stream (4 channels: cflX, cflB, blockInfo, epfSharpness)
            let nbBlocksBits = ceilLog2Int(regionBlocks)
            let nbBlocks: Int
            if nbBlocksBits > 0 {
                let rawNB = try groupReader.read(bits: nbBlocksBits)
                nbBlocks = Int(rawNB) + 1
            } else {
                nbBlocks = 1
            }
            guard nbBlocks >= 1, nbBlocks <= regionBlocks else {
                throw ScalarModularError.invalidInput("Invalid nb_blocks in VarDCT LfGroup")
            }

            let regionTilesW = (regionW + 7) / 8
            let regionTilesH = (regionH + 7) / 8
            let metaPlanes = try decodeModularSubstream(
                dimensions: [
                    (regionTilesW, regionTilesH, 0, 0),
                    (regionTilesW, regionTilesH, 0, 0),
                    (nbBlocks, 2, 0, 0),
                    (regionW, regionH, 0, 0)
                ],
                groupId: Int32(1 + 2 * numDCGroups + dcGroup),
                globalEntropy: globalEntropy,
                bitDepth: bitsPerSample,
                from: &groupReader,
                budget: budget
            )

            let tx0 = bx0 / 8
            let ty0 = by0 / 8
            for ty in 0..<regionTilesH {
                let srcRow = ty * regionTilesW
                let dstRow = (ty0 + ty) * tilesX + tx0
                for tx in 0..<regionTilesW {
                    cflX[dstRow + tx] = metaPlanes[0].pixels[srcRow + tx]
                    cflB[dstRow + tx] = metaPlanes[1].pixels[srcRow + tx]
                }
            }

            let blockInfoPixels = metaPlanes[2].pixels
            let grid = try VarDCTStrategyMap.read(
                blockInfoPixels,
                count: nbBlocks,
                width: regionW,
                height: regionH,
                budget: budget
            )

            for t in grid.transforms {
                guard t.quantisation >= 1, t.quantisation <= 256 else {
                    throw ScalarModularError.invalidInput("VarDCT quantisation field out of range")
                }
                let globalT = VarDCTStrategyMap.Transform(
                    identifier: t.identifier,
                    x: bx0 + t.x,
                    y: by0 + t.y,
                    cellsX: t.cellsX,
                    cellsY: t.cellsY,
                    quantisation: t.quantisation,
                    coefficientOffset: totalACCoefficients + t.coefficientOffset
                )
                allTransforms.append(globalT)
            }
            totalACCoefficients = try ScalarOperationBudget.sum(totalACCoefficients, grid.coefficientCount)

            let sharpPixels = metaPlanes[3].pixels
            for ry in 0..<regionH {
                let srcRow = ry * regionW
                let dstRow = (by0 + ry) * blocksX + bx0
                for rx in 0..<regionW {
                    let localTransform = grid.transforms[grid.indices[srcRow + rx]]
                    let qVal = localTransform.quantisation
                    let sVal = sharpPixels[srcRow + rx]
                    guard qVal >= 1, qVal <= 256, sVal >= 0, sVal < 8 else {
                        throw ScalarModularError.invalidInput("Invalid VarDCT block quantisation or EPF sharpness")
                    }
                    strategies[dstRow + rx] = Int32(localTransform.identifier)
                    quantField[dstRow + rx] = qVal
                    sharpnessField[dstRow + rx] = sVal
                }
            }

            if singleSection {
                sec0Reader = groupReader
            } else {
                try groupReader.expectZeroPadding()
                guard groupReader.isExhausted else {
                    throw ScalarModularError.invalidInput("Unexpected trailing bytes in VarDCT LfGroup section")
                }
            }
        }

        // --- 3. HfGlobal (ISO/IEC 18181-1 §9.3.3) ---
        var hfGlobalReader = singleSection ? sec0Reader : try envelope.section(1 + numDCGroups)
        let dequantAllDefault = try hfGlobalReader.readBit()
        guard dequantAllDefault else {
            throw ScalarModularError.unsupportedProfile
        }

        let numPresetsBits = ceilLog2Int(numGroups)
        let numHfPresets: Int
        if numPresetsBits > 0 {
            let rawPresets = try hfGlobalReader.read(bits: numPresetsBits)
            numHfPresets = Int(rawPresets) + 1
        } else {
            numHfPresets = 1
        }
        guard numHfPresets >= 1, numHfPresets <= numGroups else {
            throw ScalarModularError.invalidInput("Invalid num_hf_presets in VarDCT HfGlobal")
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
            sec0Reader = hfGlobalReader
        } else {
            try hfGlobalReader.expectZeroPadding()
            guard hfGlobalReader.isExhausted else {
                throw ScalarModularError.invalidInput("Unexpected trailing bytes in VarDCT HfGlobal section")
            }
        }

        // --- 4. HfPass sections (ISO/IEC 18181-1 §9.3.4) ---
        var ac = [
            [Int32](repeating: 0, count: totalACCoefficients),
            [Int32](repeating: 0, count: totalACCoefficients),
            [Int32](repeating: 0, count: totalACCoefficients),
        ]

        // Index transforms by their top-left (x, y) block coordinate for O(1) lookup per block
        var transformAtBlock = [Int](repeating: -1, count: totalBlocks)
        for (idx, t) in allTransforms.enumerated() {
            transformAtBlock[t.y * blocksX + t.x] = idx
        }

        let firstACSection = 2 + numDCGroups
        for groupIndex in 0..<numGroups {
            try budget.checkpoint()
            let gx = groupIndex % groupsX
            let gy = groupIndex / groupsX
            let bx0 = gx * acGroupBlocks
            let by0 = gy * acGroupBlocks
            let groupBlocksW = min(acGroupBlocks, blocksX - bx0)
            let groupBlocksH = min(acGroupBlocks, blocksY - by0)
            let groupCellCount = groupBlocksW * groupBlocksH

            var passReader = singleSection ? sec0Reader : try envelope.section(firstACSection + groupIndex)

            let presetBits = ceilLog2Int(numHfPresets)
            let hfPreset: Int
            if presetBits > 0 {
                let rawPreset = try passReader.read(bits: presetBits)
                hfPreset = Int(rawPreset)
            } else {
                hfPreset = 0
            }
            guard hfPreset >= 0, hfPreset < numHfPresets else {
                throw ScalarModularError.invalidInput("Out-of-bounds hf_preset in VarDCT HfPass")
            }

            let presetContextOffset = hfPreset * VarDCTEntropy.contextsPerBlockCluster * hfBlockCtx.numBlockClusters
            var acStream = TokenStreamReader(header: acEntropyHeader, codebook: acCodebook)
            var nzGrids = [
                [Int32](repeating: 0, count: groupCellCount),
                [Int32](repeating: 0, count: groupCellCount),
                [Int32](repeating: 0, count: groupCellCount),
            ]

            for ly in 0..<groupBlocksH {
                try budget.checkpoint()
                let by = by0 + ly
                for lx in 0..<groupBlocksW {
                    let bx = bx0 + lx
                    let tIndex = transformAtBlock[by * blocksX + bx]
                    if tIndex < 0 { continue }
                    let transform = allTransforms[tIndex]
                    let cx = transform.cellsX
                    let cy = transform.cellsY
                    let covered = transform.coveredCells
                    let log2Covered = covered.trailingZeroBitCount
                    let coeffCount = covered * 64
                    let orderBucket = transform.orderBucket
                    let baseOffset = transform.coefficientOffset
                    let blockIdx = by * blocksX + bx

                    for c in [1, 0, 2] {
                        let predictedNZ = nzGrids[c].withUnsafeBufferPointer { gridPtr in
                            VarDCTEntropy.predictedNonZeros(
                                x: lx,
                                y: ly,
                                width: groupBlocksW,
                                grid: gridPtr
                            )
                        }
                        let blockCluster = hfBlockCtx.cluster(
                            channel: c,
                            orderBucket: orderBucket,
                            quant: Int32(transform.quantisation),
                            dcX: dc[0][blockIdx],
                            dcY: dc[1][blockIdx],
                            dcB: dc[2][blockIdx]
                        )
                        let nzCtx = presetContextOffset + VarDCTEntropy.nonZeroContext(
                            predicted: predictedNZ,
                            blockContext: blockCluster,
                            numBlockClusters: hfBlockCtx.numBlockClusters
                        )
                        let nonZeros = Int(try acStream.readToken(context: nzCtx, from: &passReader))
                        guard nonZeros >= 0, nonZeros <= coeffCount - covered else {
                            throw ScalarModularError.invalidInput("Invalid AC non-zero count in VarDCT HfPass")
                        }

                        let normNZValue = Int32((nonZeros + covered - 1) >> log2Covered)
                        for dy in 0..<cy where (ly + dy) < groupBlocksH {
                            let rowBase = (ly + dy) * groupBlocksW
                            for dx in 0..<cx where (lx + dx) < groupBlocksW {
                                nzGrids[c][rowBase + (lx + dx)] = normNZValue
                            }
                        }

                        if nonZeros == 0 { continue }

                        let order = passOrders[orderBucket][c]
                        guard order.count == coeffCount else {
                            throw ScalarModularError.invalidInput("Missing scan order for VarDCT transform")
                        }

                        var remainingNZ = nonZeros
                        var prev = (nonZeros > (coeffCount >> 4)) ? 0 : 1
                        try order.withUnsafeBufferPointer { ordBuf in
                            try ac[c].withUnsafeMutableBufferPointer { acBuf in
                                let ordPtr = ordBuf.baseAddress!
                                let acPtr = acBuf.baseAddress! + baseOffset
                                for k in covered..<coeffCount {
                                    if remainingNZ == 0 { break }
                                    let zCtx = presetContextOffset + VarDCTEntropy.zeroDensityContext(
                                        nonZerosLeft: remainingNZ,
                                        k: k,
                                        log2CoveredBlocks: log2Covered,
                                        prev: prev,
                                        blockContext: blockCluster,
                                        numBlockClusters: hfBlockCtx.numBlockClusters
                                    )
                                    let rawToken = try acStream.readToken(context: zCtx, from: &passReader)
                                    let coeff = ZigZag.unpack(rawToken)
                                    acPtr[ordPtr[k]] = coeff
                                    if coeff != 0 {
                                        remainingNZ -= 1
                                        prev = 1
                                    } else {
                                        prev = 0
                                    }
                                }
                            }
                        }
                        guard remainingNZ == 0 else {
                            throw ScalarModularError.invalidInput("Unconsumed non-zero count in VarDCT HfPass")
                        }
                    }
                }
            }

            try acStream.finish(from: &passReader)

            // Optional extra-channel HfPass Modular sub-stream (for channels with min(hshift, vshift) < 3)
            if var img = extraImage {
                let slices = groupSlicesForExtra(
                    image: img,
                    firstNonGlobal: extraFirstNonGlobal,
                    gx: gx,
                    gy: gy,
                    baseDim: groupDim,
                    isDCGroup: false
                )
                if !slices.isEmpty {
                    let planes = try decodeModularSubstream(
                        dimensions: slices.map { ($0.width, $0.height, $0.hshift, $0.vshift) },
                        groupId: Int32(1 + 3 * numDCGroups + 17 + groupIndex),
                        globalEntropy: globalEntropy,
                        bitDepth: bitsPerSample,
                        from: &passReader,
                        budget: budget
                    )
                    for (i, slice) in slices.enumerated() {
                        copySliceIntoChannel(planes[i], slice: slice, into: &img.channels[slice.channelIndex])
                    }
                    extraImage = img
                }
            }

            try passReader.expectZeroPadding()
            guard passReader.isExhausted else {
                throw ScalarModularError.invalidInput("Unexpected trailing bytes in VarDCT HfPass section")
            }
        }

        // --- 5. Finalize optional alpha channel ---
        var decodedAlpha: [Int32]? = nil
        if var img = extraImage {
            if !extraGlobalTransforms.isEmpty {
                try applyInverseTransforms(
                    image: &img,
                    transforms: extraGlobalTransforms,
                    bitDepth: bitsPerSample,
                    budget: budget
                )
            }
            guard img.nbMetaChannels == 0,
                  img.channels.count == 1,
                  img.channels[0].width == width,
                  img.channels[0].height == height else {
                throw ScalarModularError.invalidInput("Invalid extra channel after Modular inverse transforms")
            }
            let maxU = UInt32(bitPattern: sampleMax)
            for v in img.channels[0].pixels {
                guard UInt32(bitPattern: v) <= maxU else {
                    throw ScalarModularError.invalidInput("Extra channel sample outside declared bit depth")
                }
            }
            decodedAlpha = img.channels[0].pixels
        }

        try budget.checkpoint()
        return Self(
            envelope: envelope,
            width: width,
            height: height,
            blocksX: blocksX,
            blocksY: blocksY,
            globalScale: globalScale,
            quantLF: quantLF,
            lfDequant: lfDequant,
            extraPrecision: frameExtraPrecision ?? 0,
            colorFactor: colorFactor,
            baseCorrelationX: baseCorrelationX,
            baseCorrelationB: baseCorrelationB,
            ytoxLF: ytoxLF,
            ytobLF: ytobLF,
            dc: dc,
            cflX: cflX,
            cflB: cflB,
            tilesX: tilesX,
            tilesY: tilesY,
            transforms: allTransforms,
            strategies: strategies,
            quantField: quantField,
            sharpnessField: sharpnessField,
            ac: ac,
            alpha: decodedAlpha
        )
    }
}

// MARK: - Internal Helpers for VarDCTCoefficients

private struct HFBlockContextDescriptor: Sendable {
    let lfThresholds: [[Int32]]
    let qfThresholds: [Int32]
    let blockCtxMap: [Int]
    let numBlockClusters: Int

    static func read(from reader: inout BitReader, budget: ScalarOperationBudget) throws -> Self {
        try budget.checkpoint()
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
            let countBits = try reader.read(bits: 4)
            let count = Int(countBits)
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

        let qfCountBits = try reader.read(bits: 4)
        let qfCount = Int(qfCountBits)
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
            throw ScalarModularError.invalidInput("HfBlockContext table size exceeds limit")
        }
        let cmap = try ContextMap.read(numContexts: bsize, from: &reader)
        guard cmap.numClusters >= 1, cmap.numClusters <= 16 else {
            throw ScalarModularError.invalidInput("HfBlockContext cluster count exceeds limit")
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

private struct ExtraGroupSlice: Sendable {
    let channelIndex: Int
    let x0: Int
    let y0: Int
    let width: Int
    let height: Int
    let hshift: Int
    let vshift: Int
}

private func groupSlicesForExtra(
    image: ModularImage,
    firstNonGlobal: Int,
    gx: Int,
    gy: Int,
    baseDim: Int,
    isDCGroup: Bool
) -> [ExtraGroupSlice] {
    var slices: [ExtraGroupSlice] = []
    for i in firstNonGlobal..<image.channels.count {
        let ch = image.channels[i]
        let dcMatch = (ch.hshift >= 3 && ch.vshift >= 3)
        if dcMatch != isDCGroup { continue }
        let hs = max(0, ch.hshift)
        let vs = max(0, ch.vshift)
        let x0 = (gx * baseDim) >> hs
        let y0 = (gy * baseDim) >> vs
        let x1 = min(ch.width, ((gx + 1) * baseDim) >> hs)
        let y1 = min(ch.height, ((gy + 1) * baseDim) >> vs)
        if x0 < x1 && y0 < y1 {
            slices.append(ExtraGroupSlice(
                channelIndex: i,
                x0: x0,
                y0: y0,
                width: x1 - x0,
                height: y1 - y0,
                hshift: ch.hshift,
                vshift: ch.vshift
            ))
        }
    }
    return slices
}

private func copySliceIntoChannel(
    _ source: ModularChannel,
    slice: ExtraGroupSlice,
    into destination: inout ModularChannel
) {
    let dstStride = destination.width
    let srcStride = slice.width
    for ry in 0..<slice.height {
        let srcRow = ry * srcStride
        let dstRow = (slice.y0 + ry) * dstStride + slice.x0
        for rx in 0..<slice.width {
            destination.pixels[dstRow + rx] = source.pixels[srcRow + rx]
        }
    }
}

private func selectModularEntropy(
    header: GroupHeader,
    globalEntropy: ModularFrameDecoder.EntropyBundle?,
    from reader: inout BitReader,
    pixelCount: Int,
    budget: ScalarOperationBudget
) throws -> ModularFrameDecoder.EntropyBundle {
    if header.useGlobalTree {
        guard let globalEntropy else {
            throw ScalarModularError.invalidInput("VarDCT Modular sub-stream requested missing global tree")
        }
        return globalEntropy
    }
    let raw = try ScalarModularDecoder.readTreeAndCodebook(from: &reader, pixelCount: pixelCount)
    try budget.reserveWorkspace(ScalarOperationBudget.product(raw.2.ansCounts.count, 64 * 1024))
    return (raw.0, raw.1, raw.2)
}

private func decodeModularSubstream(
    dimensions: [(width: Int, height: Int, hshift: Int, vshift: Int)],
    groupId: Int32,
    globalEntropy: ModularFrameDecoder.EntropyBundle?,
    bitDepth: Int,
    from reader: inout BitReader,
    budget: ScalarOperationBudget
) throws -> [ModularChannel] {
    let groupHeader = try GroupHeader.read(from: &reader)
    let pixelCount = dimensions.reduce(0) { $0 + $1.width * $1.height }
    let entropy = try selectModularEntropy(
        header: groupHeader,
        globalEntropy: globalEntropy,
        from: &reader,
        pixelCount: pixelCount,
        budget: budget
    )
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
    let maxW = subImage.channels.map({ $0.width }).max() ?? 0
    var stream = TokenStreamReader(
        header: entropy.header,
        codebook: entropy.codebook,
        distanceMultiplier: maxW
    )
    for i in subImage.channels.indices {
        try subImage.channels[i].allocatePixels(budget: budget)
        try decodeModularChannelArray(
            channel: &subImage.channels[i],
            staticChannel: Int32(i),
            groupId: groupId,
            tree: entropy.tree,
            stream: &stream,
            from: &reader,
            wpHeader: groupHeader.wpHeader,
            budget: budget
        )
    }
    try stream.finish(from: &reader)
    if !localTransforms.isEmpty {
        try applyInverseTransforms(
            image: &subImage,
            transforms: localTransforms,
            bitDepth: bitDepth,
            budget: budget
        )
    }
    guard subImage.channels.count == dimensions.count else {
        throw ScalarModularError.invalidInput("Modular sub-stream channel count mismatch after inverse transforms")
    }
    return subImage.channels
}

private func decodeModularChannelArray(
    channel: inout ModularChannel,
    staticChannel: Int32,
    groupId: Int32,
    tree: ModularTree,
    stream: inout TokenStreamReader,
    from reader: inout BitReader,
    wpHeader: WeightedPredictorHeader,
    budget: ScalarOperationBudget
) throws {
    if channel.sampleCount == 0 { return }
    try budget.reserveWorkspace(
        ScalarOperationBudget.sum(ScalarOperationBudget.product(channel.width + 2, 192), 1024)
    )
    try channel.pixels.withUnsafeMutableBufferPointer { ptr in
        var target = ptr
        try decodeModularChannel(
            width: channel.width,
            height: channel.height,
            staticChannel: staticChannel,
            groupId: groupId,
            tree: tree,
            stream: &stream,
            from: &reader,
            wpHeader: wpHeader,
            sampleMaximum: nil,
            out: &target
        )
    }
}

@inline(__always)
private func ceilLog2Int(_ n: Int) -> Int {
    guard n > 1 else { return 0 }
    return Int.bitWidth - (n - 1).leadingZeroBitCount
}
