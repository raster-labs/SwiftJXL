// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Forward ISO/IEC 18181-1 VarDCT frame bitstream writer (`LfGlobal`, `LfGroup`, `HfGlobal`, `HfPass`).
struct VarDCTFrameWriter {
    static let order: [Int] = {
        var out = [0]
        for diag in 1..<15 {
            let lo = max(0, diag - 7)
            let hi = min(7, diag)
            if (diag & 1) == 1 {
                for y in lo...hi {
                    let x = diag - y
                    out.append(y * 8 + x)
                }
            } else {
                for y in (lo...hi).reversed() {
                    let x = diag - y
                    out.append(y * 8 + x)
                }
            }
        }
        return out
    }()

    let coefficients: VarDCTPixelEncoder.Coefficients
    let source: VarDCTBorrowedSource
    let budget: ScalarOperationBudget
    let limit: Int

    private static let groupDimension = 256
    private static let acGroupBlocks = 32
    private static let dcGroupBlocks = 256
    private static let totalACContexts = VarDCTEntropy.contextsPerBlockCluster * VarDCTEntropy.defaultNumBlockClusters

    func write() throws -> Data {
        try budget.checkpoint()
        let width = coefficients.width
        let height = coefficients.height
        let blocksX = coefficients.blocksX
        let blocksY = coefficients.blocksY
        let groupsX = (width - 1) / Self.groupDimension + 1
        let groupsY = (height - 1) / Self.groupDimension + 1
        let numGroups = try ScalarOperationBudget.product(groupsX, groupsY)
        let dcGroupsX = (width - 1) / (Self.groupDimension * 8) + 1
        let dcGroupsY = (height - 1) / (Self.groupDimension * 8) + 1
        let numDCGroups = try ScalarOperationBudget.product(dcGroupsX, dcGroupsY)
        let singleSection = (numGroups == 1)
        let alphaIsGlobal = coefficients.hasAlpha && width <= Self.groupDimension && height <= Self.groupDimension

        // Precompute natural scan orders for all used transform buckets
        var bucketOrders = [[Int]?](repeating: nil, count: VarDCTOrders.orderCount)
        for transform in coefficients.transforms {
            let bucket = transform.orderBucket
            if bucketOrders[bucket] == nil {
                let dims = VarDCTOrders.orderDimensions[bucket]
                bucketOrders[bucket] = bucket == 1
                    ? try VarDCTOrders.naturalAFV(budget: budget)
                    : try VarDCTOrders.natural(width: dims.width, height: dims.height, budget: budget)
            }
        }
        if bucketOrders[0] == nil {
            bucketOrders[0] = Self.order
        }

        // Index transforms by top-left block coordinate
        let totalBlocks = try ScalarOperationBudget.product(blocksX, blocksY)
        var transformAtBlock = [Int](repeating: -1, count: totalBlocks)
        for (idx, t) in coefficients.transforms.enumerated() {
            transformAtBlock[t.y * blocksX + t.x] = idx
        }

        // 1. Build Modular token histogram across all Modular substreams (extra, dc, hfMetadata)
        let postCfg = HybridUintConfig.raw4
        var modularHisto = [Int](repeating: 0, count: postCfg.maxToken + 1)
        var modularMaxTok = 0

        @inline(__always)
        func raw4Token(_ value: UInt32) -> Int {
            if value < 16 { return Int(value) }
            return 12 &+ (31 &- value.leadingZeroBitCount)
        }

        @inline(__always)
        func recordModularToken(_ value: UInt32) {
            let tok = raw4Token(value)
            modularHisto[tok] += 1
            if tok > modularMaxTok { modularMaxTok = tok }
        }

        if alphaIsGlobal {
            try scanAlphaSliceResiduals(x0: 0, y0: 0, sliceW: width, sliceH: height, emit: recordModularToken)
        }

        for dcGroup in 0..<numDCGroups {
            try budget.checkpoint()
            let dcx = dcGroup % dcGroupsX
            let dcy = dcGroup / dcGroupsX
            let bx0 = dcx * Self.dcGroupBlocks
            let by0 = dcy * Self.dcGroupBlocks
            let regionW = min(Self.dcGroupBlocks, blocksX - bx0)
            let regionH = min(Self.dcGroupBlocks, blocksY - by0)

            // 3 DC channels in stream order [Y=1, X=0, B=2]
            for c in [1, 0, 2] {
                scanPlaneResiduals(
                    plane: coefficients.dc[c],
                    planeWidth: blocksX,
                    x0: bx0,
                    y0: by0,
                    w: regionW,
                    h: regionH,
                    emit: recordModularToken
                )
            }

            // HfMetadata: cflX (tilesW x tilesH = zeros), cflB (zeros), blockInfo (nbBlocks x 2), sharpness (regionW x regionH = zeros)
            let regionTilesW = (regionW + 7) / 8
            let regionTilesH = (regionH + 7) / 8
            let zeroTileCount = regionTilesW * regionTilesH * 2
            for _ in 0..<zeroTileCount {
                recordModularToken(0)
            }

            let groupTransforms = transformsInDCGroup(
                bx0: bx0, by0: by0, regionW: regionW, regionH: regionH, transformAtBlock: transformAtBlock
            )
            let nbBlocks = max(1, groupTransforms.count)
            var blockInfo = [Int32](repeating: 0, count: nbBlocks * 2)
            for (i, t) in groupTransforms.enumerated() {
                blockInfo[i] = Int32(t.identifier)
                blockInfo[nbBlocks + i] = Int32(t.quantisation) - 1
            }
            scanPlaneResiduals(plane: blockInfo, planeWidth: nbBlocks, x0: 0, y0: 0, w: nbBlocks, h: 2, emit: recordModularToken)

            let sharpCount = regionW * regionH
            for _ in 0..<sharpCount {
                recordModularToken(0)
            }
        }

        if coefficients.hasAlpha && !alphaIsGlobal {
            for groupIndex in 0..<numGroups {
                try budget.checkpoint()
                let gx = groupIndex % groupsX
                let gy = groupIndex / groupsX
                let x0 = gx * Self.groupDimension
                let y0 = gy * Self.groupDimension
                let sliceW = min(Self.groupDimension, width - x0)
                let sliceH = min(Self.groupDimension, height - y0)
                try scanAlphaSliceResiduals(x0: x0, y0: y0, sliceW: sliceW, sliceH: sliceH, emit: recordModularToken)
            }
        }

        let modularAlpha = max(2, modularMaxTok + 1)
        let modularLengths = lengthLimitedCanonicalHuffman(
            counts: Array(modularHisto[0..<modularAlpha]),
            maxLength: 15,
            alphabetSize: modularAlpha
        )
        let modularTable = try PrefixCodeTable(lengths: modularLengths)
        let modularCodebook = MultiClusterCodebook(
            huffmanTables: [modularTable],
            ansCounts: [],
            alphabetSizes: [modularAlpha]
        )
        let modularHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: ContextMap.trivial(numContexts: 1),
            usePrefixCode: true,
            logAlphaSize: 15,
            uintConfigs: [postCfg]
        )
        let modularWriter = TokenStreamWriter(header: modularHeader, codebook: modularCodebook)

        // 2. Build AC token histogram across all HfPass groups
        var acHisto = [Int](repeating: 0, count: postCfg.maxToken + 1)
        var acMaxTok = 0

        @inline(__always)
        func recordACToken(_ value: UInt32) {
            let tok = raw4Token(value)
            acHisto[tok] += 1
            if tok > acMaxTok { acMaxTok = tok }
        }

        let channelOrder = [1, 0, 2]
        for groupIndex in 0..<numGroups {
            try budget.checkpoint()
            let gx = groupIndex % groupsX
            let gy = groupIndex / groupsX
            let bx0 = gx * Self.acGroupBlocks
            let by0 = gy * Self.acGroupBlocks
            let groupBlocksW = min(Self.acGroupBlocks, blocksX - bx0)
            let groupBlocksH = min(Self.acGroupBlocks, blocksY - by0)

            for ly in 0..<groupBlocksH {
                let by = by0 + ly
                for lx in 0..<groupBlocksW {
                    let bx = bx0 + lx
                    let tIndex = transformAtBlock[by * blocksX + bx]
                    if tIndex < 0 { continue }
                    let transform = coefficients.transforms[tIndex]
                    let covered = transform.coveredCells
                    let coeffCount = covered * 64
                    let baseOffset = transform.coefficientOffset
                    let order = bucketOrders[transform.orderBucket]!

                    order.withUnsafeBufferPointer { ordBuf in
                        let ordPtr = ordBuf.baseAddress!
                        for c in channelOrder {
                            coefficients.ac[c].withUnsafeBufferPointer { acBuf in
                                let planePtr = acBuf.baseAddress! + baseOffset
                                var nonZeros = 0
                                var lastNZ = -1
                                for k in covered..<coeffCount {
                                    if planePtr[ordPtr[k]] != 0 {
                                        nonZeros += 1
                                        lastNZ = k
                                    }
                                }
                                recordACToken(UInt32(nonZeros))
                                if nonZeros == 0 { return }
                                for k in covered...lastNZ {
                                    let v = planePtr[ordPtr[k]]
                                    recordACToken(ZigZag.pack(v))
                                }
                            }
                        }
                    }
                }
            }
        }

        let acAlpha = max(2, acMaxTok + 1)
        let acLengths = lengthLimitedCanonicalHuffman(
            counts: Array(acHisto[0..<acAlpha]),
            maxLength: 15,
            alphabetSize: acAlpha
        )
        let acTable = try PrefixCodeTable(lengths: acLengths)
        let acCodebook = MultiClusterCodebook(
            huffmanTables: [acTable],
            ansCounts: [],
            alphabetSizes: [acAlpha]
        )
        let acHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: ContextMap.trivial(numContexts: Self.totalACContexts),
            usePrefixCode: true,
            logAlphaSize: 15,
            uintConfigs: [postCfg]
        )
        let acWriter = TokenStreamWriter(header: acHeader, codebook: acCodebook)

        // 3. Emit section bitstreams
        var sectionData: [Data] = []
        var currentWriter = BitWriter()

        // --- 3a. LfGlobal ---
        try writeLfGlobal(
            to: &currentWriter,
            modularHeader: modularHeader,
            modularCodebook: modularCodebook,
            modularWriter: modularWriter,
            alphaIsGlobal: alphaIsGlobal
        )
        if !singleSection {
            currentWriter.alignToByte()
            sectionData.append(currentWriter.finishToData())
            currentWriter = BitWriter()
        }

        // --- 3b. LfGroups ---
        for dcGroup in 0..<numDCGroups {
            try budget.checkpoint()
            let dcx = dcGroup % dcGroupsX
            let dcy = dcGroup / dcGroupsX
            let bx0 = dcx * Self.dcGroupBlocks
            let by0 = dcy * Self.dcGroupBlocks
            let regionW = min(Self.dcGroupBlocks, blocksX - bx0)
            let regionH = min(Self.dcGroupBlocks, blocksY - by0)

            try writeLfGroup(
                to: &currentWriter,
                bx0: bx0,
                by0: by0,
                regionW: regionW,
                regionH: regionH,
                transformAtBlock: transformAtBlock,
                modularWriter: modularWriter
            )
            if !singleSection {
                currentWriter.alignToByte()
                sectionData.append(currentWriter.finishToData())
                currentWriter = BitWriter()
            }
        }

        // --- 3c. HfGlobal ---
        try writeHfGlobal(
            to: &currentWriter,
            numGroups: numGroups,
            acHeader: acHeader,
            acCodebook: acCodebook
        )
        if !singleSection {
            currentWriter.alignToByte()
            sectionData.append(currentWriter.finishToData())
            currentWriter = BitWriter()
        }

        // --- 3d. HfPasses ---
        for groupIndex in 0..<numGroups {
            try budget.checkpoint()
            let gx = groupIndex % groupsX
            let gy = groupIndex / groupsX
            let bx0 = gx * Self.acGroupBlocks
            let by0 = gy * Self.acGroupBlocks
            let groupBlocksW = min(Self.acGroupBlocks, blocksX - bx0)
            let groupBlocksH = min(Self.acGroupBlocks, blocksY - by0)

            try writeHfPass(
                to: &currentWriter,
                gx: gx,
                gy: gy,
                bx0: bx0,
                by0: by0,
                groupBlocksW: groupBlocksW,
                groupBlocksH: groupBlocksH,
                transformAtBlock: transformAtBlock,
                bucketOrders: bucketOrders,
                acWriter: acWriter,
                modularWriter: modularWriter,
                alphaInPass: coefficients.hasAlpha && !alphaIsGlobal
            )
            currentWriter.alignToByte()
            sectionData.append(currentWriter.finishToData())
            if groupIndex + 1 < numGroups {
                currentWriter = BitWriter()
            }
        }

        // 4. Write outer codestream header + TOC + sections
        let totalSectionBytes = sectionData.reduce(0) { $0 + $1.count }
        var outer = BitWriter(reservingBytes: totalSectionBytes + 256)
        outer.write(bits: 8, value: 0xFF)
        outer.write(bits: 8, value: 0x0A)
        try SizeHeader(xsize: UInt32(width), ysize: UInt32(height)).write(to: &outer)

        let extraChannels: [ExtraChannelInfo] = coefficients.hasAlpha ? [
            ExtraChannelInfo(
                type: .alpha,
                bitDepth: BitDepth(floatingPoint: false, bitsPerSample: UInt32(coefficients.bits)),
                dimShift: 0,
                name: "",
                alphaAssociated: false
            )
        ] : []

        let metadata = ImageMetadata(
            allDefault: false,
            orientation: 1,
            intrinsicSize: nil,
            preview: nil,
            animation: nil,
            bitDepth: BitDepth(floatingPoint: false, bitsPerSample: UInt32(coefficients.bits)),
            modular16BitBufferSufficient: true,
            extraChannels: extraChannels,
            xybEncoded: true,
            colorEncoding: coefficients.grayscale ? .grayscaleD65 : .srgb,
            intensityTarget: 255.0,
            minNits: 0.0,
            relativeToMaxDisplay: false,
            linearBelow: 0.0
        )
        try metadata.write(to: &outer)
        outer.writeBit(true) // CustomTransformData.all_default = true
        outer.alignToByte()

        let frameHeader = FrameHeader(
            allDefault: false,
            frameType: .regular,
            encoding: .varDCT,
            flags: coefficients.dcSmoothing ? 0 : 128,
            colorTransform: .xyb,
            chromaSubsampling: .default,
            upsampling: 1,
            extraChannelUpsampling: coefficients.hasAlpha ? [1] : [],
            groupSizeShift: 1,
            xQmScale: 2,
            bQmScale: 2,
            passes: .default,
            dcLevel: 0,
            customSizeOrOrigin: false,
            frameOrigin: (0, 0),
            frameSize: nil,
            blendingInfo: .default,
            extraChannelBlendingInfo: coefficients.hasAlpha ? [.default] : [],
            animationFrame: .default,
            isLast: true,
            saveAsReference: 0,
            saveBeforeColorTransform: false,
            name: "",
            loopFilter: LoopFilter(
                allDefault: false,
                gab: coefficients.gaborish,
                epfIters: 0
            )
        )
        let frameCtx = FrameHeaderContext(
            xybEncoded: true,
            numExtraChannels: extraChannels.count,
            haveAnimation: false,
            haveTimecodes: false
        )
        try frameHeader.write(to: &outer, context: frameCtx)

        var offsets: [UInt64] = [0]
        var runningOffset: UInt64 = 0
        for s in sectionData {
            runningOffset += UInt64(s.count)
            offsets.append(runningOffset)
        }
        let toc = TOC(
            hasPermutation: false,
            entrySizes: sectionData.map { UInt32($0.count) },
            offsets: offsets
        )
        try toc.write(to: &outer)

        var output = outer.finishToData()
        for s in sectionData {
            output.append(s)
        }
        guard output.count <= limit else {
            throw ScalarModularError.resourceLimit
        }
        return output
    }

    // MARK: - Section Writers

    private func writeLfGlobal(
        to w: inout BitWriter,
        modularHeader: EntropySectionHeader,
        modularCodebook: MultiClusterCodebook,
        modularWriter: TokenStreamWriter,
        alphaIsGlobal: Bool
    ) throws {
        // LfChannelDequantization.all_default = true
        w.writeBit(true)
        // Quantizer: global_scale and quant_lf = 17
        try w.writeU32(
            UInt32(coefficients.globalScale),
            distributions: (
                .offset(constant: 1, extraBits: 11),
                .offset(constant: 2049, extraBits: 11),
                .offset(constant: 4097, extraBits: 12),
                .offset(constant: 8193, extraBits: 16)
            )
        )
        try w.writeU32(
            17,
            distributions: (
                .literal(16),
                .offset(constant: 1, extraBits: 5),
                .offset(constant: 1, extraBits: 8),
                .offset(constant: 1, extraBits: 16)
            )
        )
        // HfBlockContext: is_default = true
        w.writeBit(true)
        // LfChannelCorrelation: all_default = true
        w.writeBit(true)
        // Global Modular Tree: has_tree = true
        w.writeBit(true)

        let treeUintCfg = HybridUintConfig(splitExponent: 0, msbInToken: 0, lsbInToken: 0)
        let treeTable = try PrefixCodeTable(lengths: [UInt8](repeating: 4, count: 16))
        let treeCodebook = MultiClusterCodebook(
            huffmanTables: [treeTable],
            ansCounts: [],
            alphabetSizes: [16]
        )
        let treeHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: ContextMap.trivial(numContexts: 6),
            usePrefixCode: true,
            logAlphaSize: 15,
            uintConfigs: [treeUintCfg]
        )
        try treeHeader.write(to: &w, numContexts: 6)
        try treeCodebook.write(to: &w, header: treeHeader)
        let tree = ModularTree(nodes: [
            ModularTreeNode(
                property: -1,
                splitVal: 0,
                leftChildOrLeafId: 0,
                rightChild: 0,
                predictor: .gradient,
                predictorOffset: 0,
                multiplier: 1,
                rawPredictor: 5
            )
        ])
        let treeStreamWriter = TokenStreamWriter(header: treeHeader, codebook: treeCodebook)
        try tree.encode { ctx, val in
            try treeStreamWriter.writeToken(context: ctx, value: val, to: &w)
        }

        // Global post-tree Modular codebook
        try modularHeader.write(to: &w, numContexts: 1)
        try modularCodebook.write(to: &w, header: modularHeader)

        if coefficients.hasAlpha {
            try GroupHeader.default.write(to: &w)
            if alphaIsGlobal {
                try scanAlphaSliceResiduals(x0: 0, y0: 0, sliceW: coefficients.width, sliceH: coefficients.height) { tok in
                    try modularWriter.writeToken(context: 0, value: tok, to: &w)
                }
            }
        }
    }

    private func writeLfGroup(
        to w: inout BitWriter,
        bx0: Int,
        by0: Int,
        regionW: Int,
        regionH: Int,
        transformAtBlock: [Int],
        modularWriter: TokenStreamWriter
    ) throws {
        // extra_precision = 0 (2 bits)
        w.write(bits: 2, value: 0)

        // DC Modular substream ([Y=1, X=0, B=2])
        try GroupHeader.default.write(to: &w)
        for c in [1, 0, 2] {
            try scanPlaneResiduals(
                plane: coefficients.dc[c],
                planeWidth: coefficients.blocksX,
                x0: bx0,
                y0: by0,
                w: regionW,
                h: regionH
            ) { tok in
                try modularWriter.writeToken(context: 0, value: tok, to: &w)
            }
        }

        // HfMetadata Modular substream
        let regionBlocks = regionW * regionH
        let groupTransforms = transformsInDCGroup(
            bx0: bx0, by0: by0, regionW: regionW, regionH: regionH, transformAtBlock: transformAtBlock
        )
        let nbBlocks = max(1, groupTransforms.count)
        let nbBlocksBits = Self.ceilLog2(regionBlocks)
        if nbBlocksBits > 0 {
            w.write(bits: nbBlocksBits, value: UInt32(nbBlocks - 1))
        }

        try GroupHeader.default.write(to: &w)
        let regionTilesW = (regionW + 7) / 8
        let regionTilesH = (regionH + 7) / 8
        let zeroTileCount = regionTilesW * regionTilesH * 2
        for _ in 0..<zeroTileCount {
            try modularWriter.writeToken(context: 0, value: 0, to: &w)
        }

        var blockInfo = [Int32](repeating: 0, count: nbBlocks * 2)
        for (i, t) in groupTransforms.enumerated() {
            blockInfo[i] = Int32(t.identifier)
            blockInfo[nbBlocks + i] = Int32(t.quantisation) - 1
        }
        try scanPlaneResiduals(plane: blockInfo, planeWidth: nbBlocks, x0: 0, y0: 0, w: nbBlocks, h: 2) { tok in
            try modularWriter.writeToken(context: 0, value: tok, to: &w)
        }

        let sharpCount = regionW * regionH
        for _ in 0..<sharpCount {
            try modularWriter.writeToken(context: 0, value: 0, to: &w)
        }
    }

    private func writeHfGlobal(
        to w: inout BitWriter,
        numGroups: Int,
        acHeader: EntropySectionHeader,
        acCodebook: MultiClusterCodebook
    ) throws {
        // dequant_matrices_all_default = true
        w.writeBit(true)
        // num_hf_presets = 1 (encoded as 0 in ceilLog2(numGroups) bits)
        let presetBits = Self.ceilLog2(numGroups)
        if presetBits > 0 {
            w.write(bits: presetBits, value: 0)
        }
        // used_orders = 0
        try w.writeU32(
            0,
            distributions: (.literal(0x5F), .literal(0x13), .literal(0), .bits(13))
        )
        try acHeader.write(to: &w, numContexts: Self.totalACContexts)
        try acCodebook.write(to: &w, header: acHeader)
    }

    private func writeHfPass(
        to w: inout BitWriter,
        gx: Int,
        gy: Int,
        bx0: Int,
        by0: Int,
        groupBlocksW: Int,
        groupBlocksH: Int,
        transformAtBlock: [Int],
        bucketOrders: [[Int]?],
        acWriter: TokenStreamWriter,
        modularWriter: TokenStreamWriter,
        alphaInPass: Bool
    ) throws {
        let acTable = acWriter.codebook.huffmanTables[0]
        let channelOrder = [1, 0, 2]
        acTable.lengths.withUnsafeBufferPointer { lenBuf in
            acTable.reversedCodewords.withUnsafeBufferPointer { cwBuf in
                let lengths = lenBuf.baseAddress!
                let revCodewords = cwBuf.baseAddress!

                @inline(__always)
                func emitRaw4Token(_ value: UInt32) {
                    if value < 16 {
                        let s = Int(value)
                        let l = Int(lengths[s])
                        if l > 0 { w.write(bits: l, value: revCodewords[s]) }
                    } else {
                        let n = 31 &- value.leadingZeroBitCount
                        let s = 12 &+ n
                        let l = Int(lengths[s])
                        if l > 0 { w.write(bits: l, value: revCodewords[s]) }
                        let extra = value &- (UInt32(1) &<< UInt32(n))
                        w.write(bits: n, value: extra)
                    }
                }

                for ly in 0..<groupBlocksH {
                    let by = by0 + ly
                    for lx in 0..<groupBlocksW {
                        let bx = bx0 + lx
                        let tIndex = transformAtBlock[by * coefficients.blocksX + bx]
                        if tIndex < 0 { continue }
                        let transform = coefficients.transforms[tIndex]
                        let covered = transform.coveredCells
                        let coeffCount = covered * 64
                        let baseOffset = transform.coefficientOffset
                        let order = bucketOrders[transform.orderBucket]!

                        order.withUnsafeBufferPointer { ordBuf in
                            let ordPtr = ordBuf.baseAddress!
                            for c in channelOrder {
                                coefficients.ac[c].withUnsafeBufferPointer { acBuf in
                                    let planePtr = acBuf.baseAddress! + baseOffset
                                    var nonZeros = 0
                                    var lastNZ = -1
                                    for k in covered..<coeffCount {
                                        if planePtr[ordPtr[k]] != 0 {
                                            nonZeros += 1
                                            lastNZ = k
                                        }
                                    }
                                    emitRaw4Token(UInt32(nonZeros))
                                    if nonZeros == 0 { return }
                                    for k in covered...lastNZ {
                                        let v = planePtr[ordPtr[k]]
                                        emitRaw4Token(ZigZag.pack(v))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        try budget.checkpoint()

        if alphaInPass {
            let x0 = gx * Self.groupDimension
            let y0 = gy * Self.groupDimension
            let sliceW = min(Self.groupDimension, coefficients.width - x0)
            let sliceH = min(Self.groupDimension, coefficients.height - y0)
            try GroupHeader.default.write(to: &w)
            try scanAlphaSliceResiduals(x0: x0, y0: y0, sliceW: sliceW, sliceH: sliceH) { tok in
                try modularWriter.writeToken(context: 0, value: tok, to: &w)
            }
        }
    }

    // MARK: - Helpers

    private func transformsInDCGroup(
        bx0: Int,
        by0: Int,
        regionW: Int,
        regionH: Int,
        transformAtBlock: [Int]
    ) -> [VarDCTStrategyMap.Transform] {
        var result: [VarDCTStrategyMap.Transform] = []
        result.reserveCapacity(regionW * regionH)
        for ry in 0..<regionH {
            let by = by0 + ry
            for rx in 0..<regionW {
                let bx = bx0 + rx
                let idx = transformAtBlock[by * coefficients.blocksX + bx]
                if idx >= 0 {
                    result.append(coefficients.transforms[idx])
                }
            }
        }
        return result
    }

    @inline(__always)
    private static func gradientPredict(w: Int32, n: Int32, nw: Int32) -> Int32 {
        let g = Int64(w) + Int64(n) - Int64(nw)
        let lo = Int64(min(w, n))
        let hi = Int64(max(w, n))
        return Int32(truncatingIfNeeded: min(max(g, lo), hi))
    }

    private func scanPlaneResiduals(
        plane: [Int32],
        planeWidth: Int,
        x0: Int,
        y0: Int,
        w: Int,
        h: Int,
        emit: (UInt32) throws -> Void
    ) rethrows {
        try plane.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return }
            for ry in 0..<h {
                let row = (y0 + ry) * planeWidth + x0
                let prevRow = (y0 + ry - 1) * planeWidth + x0
                for rx in 0..<w {
                    let actual = ptr[row + rx]
                    let predicted: Int32
                    if ry == 0 && rx == 0 {
                        predicted = 0
                    } else if ry == 0 {
                        predicted = ptr[row + rx - 1]
                    } else if rx == 0 {
                        predicted = ptr[prevRow]
                    } else {
                        predicted = Self.gradientPredict(
                            w: ptr[row + rx - 1],
                            n: ptr[prevRow + rx],
                            nw: ptr[prevRow + rx - 1]
                        )
                    }
                    try emit(ZigZag.pack(actual &- predicted))
                }
            }
        }
    }

    private func scanAlphaSliceResiduals(
        x0: Int,
        y0: Int,
        sliceW: Int,
        sliceH: Int,
        emit: (UInt32) throws -> Void
    ) throws {
        let alphaChannel = source.layouts.count - 1
        var prevRow = [Int32](repeating: 0, count: sliceW)
        var currRow = [Int32](repeating: 0, count: sliceW)
        for ry in 0..<sliceH {
            if (ry & 15) == 0 { try budget.checkpoint() }
            let y = y0 + ry
            for rx in 0..<sliceW {
                let actual = try source.sample(channel: alphaChannel, x: x0 + rx, y: y)
                currRow[rx] = actual
                let predicted: Int32
                if ry == 0 && rx == 0 {
                    predicted = 0
                } else if ry == 0 {
                    predicted = currRow[rx - 1]
                } else if rx == 0 {
                    predicted = prevRow[0]
                } else {
                    predicted = Self.gradientPredict(
                        w: currRow[rx - 1],
                        n: prevRow[rx],
                        nw: prevRow[rx - 1]
                    )
                }
                try emit(ZigZag.pack(actual &- predicted))
            }
            swap(&prevRow, &currRow)
        }
    }

    @inline(__always)
    private static func ceilLog2(_ n: Int) -> Int {
        guard n > 1 else { return 0 }
        return Int.bitWidth - (n - 1).leadingZeroBitCount
    }
}
