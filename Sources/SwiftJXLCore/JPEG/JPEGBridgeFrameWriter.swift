// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Writes a JPEG-bridged VarDCT codestream per ISO/IEC 18181-1 §§6, 7, 8, 9.1–9.3, Annex C.
package enum JPEGBridgeFrameWriter {
    private static let groupBlocks = 32
    private static let dcGroupBlocks = 256

    package static func write(
        _ view: JPEGBridgeCoefficients,
        maximumOutputBytes: Int = 64 * 1024 * 1024,
        iccProfile: Data? = nil,
        policy: JPEGBridgePolicy
    ) throws -> Data {
        try policy.checkpoint()

        let maxH = view.frame.components.map(\.horizontalSampling).max() ?? 1
        let maxV = view.frame.components.map(\.verticalSampling).max() ?? 1
        let fullBlocksX = view.frame.mcusWide * maxH
        let fullBlocksY = view.frame.mcusHigh * maxV
        let paddedWidth = fullBlocksX * 8
        let paddedHeight = fullBlocksY * 8

        guard view.frame.width <= 2048,
              view.frame.height <= 2048,
              paddedWidth <= 2048,
              paddedHeight <= 2048,
              fullBlocksX <= dcGroupBlocks,
              fullBlocksY <= dcGroupBlocks else {
            throw JPEGEntropyError.unsupported
        }

        let (coeffBytes, coeffOverflow) = view.frame.coefficientCount.multipliedReportingOverflow(
            by: MemoryLayout<Int32>.stride
        )
        guard !coeffOverflow,
              maximumOutputBytes > 0,
              coeffBytes <= policy.maximumCoefficientBytes,
              view.admittedBytes <= policy.maximumMemoryBytes,
              view.frame.width <= policy.maximumDimension,
              view.frame.height <= policy.maximumDimension,
              view.frame.width <= policy.maximumPixels / max(1, view.frame.height) else {
            throw JPEGEntropyError.resourceLimit
        }
        if let icc = iccProfile {
            guard icc.count <= policy.maximumICCBytes else {
                throw JPEGEntropyError.resourceLimit
            }
        }

        let groupsX = (fullBlocksX + groupBlocks - 1) / groupBlocks
        let groupsY = (fullBlocksY + groupBlocks - 1) / groupBlocks
        let numGroups = groupsX * groupsY
        let singleSection = (numGroups == 1)

        // 1. Extract DC planes and AC blocks per channel in JXL [0: Cb/G, 1: Y/R, 2: Cr/B] order
        var dcPlanes: [[Int32]] = []
        dcPlanes.reserveCapacity(3)
        for c in 0..<3 {
            let layout = view.channels[c]
            dcPlanes.append([Int32](repeating: 0, count: layout.blocksWide * layout.blocksHigh))
        }

        let naturalOrder = VarDCTFrameWriter.order
        let totalACContexts = VarDCTEntropy.contextsPerBlockCluster * VarDCTEntropy.defaultNumBlockClusters
        var groupTokens = [[(context: Int, value: UInt32)]](repeating: [], count: numGroups)
        var blockScratch = [Int32](repeating: 0, count: 64)

        for groupIdx in 0..<numGroups {
            try policy.checkpoint()
            let gx = groupIdx % groupsX
            let gy = groupIdx / groupsX
            let bx0 = gx * groupBlocks
            let by0 = gy * groupBlocks
            let gw = min(groupBlocks, fullBlocksX - bx0)
            let gh = min(groupBlocks, fullBlocksY - by0)

            var nzGrids: [[Int32]] = []
            var subWidths: [Int] = []
            for c in 0..<3 {
                let hs = view.channels[c].horizontalShift
                let vs = view.channels[c].verticalShift
                let sw = (gw + (1 << hs) - 1) >> hs
                let sh = (gh + (1 << vs) - 1) >> vs
                subWidths.append(sw)
                nzGrids.append([Int32](repeating: 0, count: sw * sh))
            }

            var tokens: [(context: Int, value: UInt32)] = []
            tokens.reserveCapacity(gw * gh * 16)

            for ly in 0..<gh {
                if (ly & 7) == 0 { try policy.checkpoint() }
                let by = by0 + ly
                for lx in 0..<gw {
                    let bx = bx0 + lx
                    for c in [1, 0, 2] {
                        let layout = view.channels[c]
                        let hs = layout.horizontalShift
                        let vs = layout.verticalShift
                        if (bx & ((1 << hs) - 1)) != 0 || (by & ((1 << vs) - 1)) != 0 {
                            continue
                        }
                        let cbx = bx >> hs
                        let cby = by >> vs
                        let clx = lx >> hs
                        let cly = ly >> vs
                        let blockIndex = cby * layout.blocksWide + cbx
                        try view.readBlock(channel: c, block: blockIndex, into: &blockScratch)
                        dcPlanes[c][blockIndex] = blockScratch[0]

                        let sw = subWidths[c]
                        let predictedNZ = nzGrids[c].withUnsafeBufferPointer { ptr in
                            VarDCTEntropy.predictedNonZeros(x: clx, y: cly, width: sw, grid: ptr)
                        }
                        let blockCluster = VarDCTEntropy.blockContext(channel: c, orderBucket: 0)
                        let nzCtx = VarDCTEntropy.nonZeroContext(
                            predicted: predictedNZ,
                            blockContext: blockCluster,
                            numBlockClusters: VarDCTEntropy.defaultNumBlockClusters
                        )

                        var nonZeros = 0
                        for k in 1..<64 where blockScratch[naturalOrder[k]] != 0 {
                            nonZeros += 1
                        }
                        tokens.append((nzCtx, UInt32(nonZeros)))
                        nzGrids[c][cly * sw + clx] = Int32(nonZeros)

                        if nonZeros == 0 { continue }

                        var remainingNZ = nonZeros
                        var prev = (nonZeros > 4) ? 0 : 1
                        for k in 1..<64 {
                            if remainingNZ == 0 { break }
                            let zCtx = VarDCTEntropy.zeroDensityContext(
                                nonZerosLeft: remainingNZ,
                                k: k,
                                log2CoveredBlocks: 0,
                                prev: prev,
                                blockContext: blockCluster,
                                numBlockClusters: VarDCTEntropy.defaultNumBlockClusters
                            )
                            let coeff = blockScratch[naturalOrder[k]]
                            tokens.append((zCtx, ZigZag.pack(coeff)))
                            if coeff != 0 {
                                remainingNZ -= 1
                                prev = 1
                            } else {
                                prev = 0
                            }
                        }
                    }
                }
            }
            groupTokens[groupIdx] = tokens
        }

        // 2. Build section bitstreams: LfGlobal, LfGroup[0], HfGlobal, HfPass[0..<numGroups]
        var sectionData: [Data] = []
        var writer = BitWriter()

        // --- 2a. LfGlobal (ISO/IEC 18181-1 §9.3.1) ---
        // LfChannelDequantization: all_default = false, followed by 3 F16 values
        writer.writeBit(false)
        for c in 0..<3 {
            let unscaled = Float(128.0) / view.dcQuantisation[c]
            writer.write(bits: 16, value: UInt32( Self.floatToHalfRounded(unscaled) ))
        }
        // Quantizer: global_scale = 65536, quant_lf = 1
        try writer.writeU32(
            65536,
            distributions: (
                .offset(constant: 1, extraBits: 11),
                .offset(constant: 2049, extraBits: 11),
                .offset(constant: 4097, extraBits: 12),
                .offset(constant: 8193, extraBits: 16)
            )
        )
        try writer.writeU32(
            1,
            distributions: (
                .literal(16),
                .offset(constant: 1, extraBits: 5),
                .offset(constant: 1, extraBits: 8),
                .offset(constant: 1, extraBits: 16)
            )
        )
        // HfBlockContext: is_default = true
        writer.writeBit(true)
        // LfChannelCorrelation: all_default = false, color_factor = 84,
        // base_correlation_x = 0.0, base_correlation_b = 0.0, ytox_lf = 128, ytob_lf = 128
        writer.writeBit(false)
        writer.write(bits: 2, value: 0)
        writer.write(bits: 16, value: 0)
        writer.write(bits: 16, value: 0)
        writer.write(bits: 8, value: 128)
        writer.write(bits: 8, value: 128)
        // Global Modular tree: has_tree = false (each Modular substream embeds its own 1-leaf tree)
        writer.writeBit(false)

        if !singleSection {
            writer.alignToByte()
            sectionData.append(writer.finishToData())
            writer = BitWriter()
        }

        // --- 2b. LfGroup[0] (ISO/IEC 18181-1 §9.3.2) ---
        // extra_precision = 0 (2 bits)
        writer.write(bits: 2, value: 0)
        // DC Modular substream in stream order [0: Y(1), 1: X/Cb(0), 2: B/Cr(2)]
        let dcStreamChannels = [dcPlanes[1], dcPlanes[0], dcPlanes[2]]
        let dcStreamDims = [
            (width: view.channels[1].blocksWide, height: view.channels[1].blocksHigh),
            (width: view.channels[0].blocksWide, height: view.channels[0].blocksHigh),
            (width: view.channels[2].blocksWide, height: view.channels[2].blocksHigh),
        ]
        try JPEGBridgeEntropy.writeFlatModularSubstream(
            channels: dcStreamChannels,
            dimensions: dcStreamDims,
            predictor: 5,
            to: &writer,
            policy: policy
        )

        // HfMetadata Modular substream: nb_blocks = fullBlocksX * fullBlocksY
        let totalBlocks = fullBlocksX * fullBlocksY
        let nbBlocksBits = Self.ceilLog2(totalBlocks)
        if nbBlocksBits > 0 {
            writer.write(bits: nbBlocksBits, value: UInt32(totalBlocks - 1))
        }
        let tilesX = (fullBlocksX + 7) / 8
        let tilesY = (fullBlocksY + 7) / 8
        let metaChannels = [
            [Int32](repeating: 0, count: tilesX * tilesY),
            [Int32](repeating: 0, count: tilesX * tilesY),
            [Int32](repeating: 0, count: totalBlocks * 2),
            [Int32](repeating: 0, count: totalBlocks),
        ]
        let metaDims = [
            (width: tilesX, height: tilesY),
            (width: tilesX, height: tilesY),
            (width: totalBlocks, height: 2),
            (width: fullBlocksX, height: fullBlocksY),
        ]
        try JPEGBridgeEntropy.writeFlatModularSubstream(
            channels: metaChannels,
            dimensions: metaDims,
            predictor: 0,
            to: &writer,
            policy: policy
        )

        if !singleSection {
            writer.alignToByte()
            sectionData.append(writer.finishToData())
            writer = BitWriter()
        }

        // --- 2c. HfGlobal (ISO/IEC 18181-1 §9.3.3 & Annex C) ---
        // DequantMatrices: all_default = false
        writer.writeBit(false)
        // Table 0 (DCT8): encoding_mode = 7 (kQuantModeRAW, 3 bits 111), denom = F16(1.0 / 2040.0)
        writer.write(bits: 3, value: 7)
        writer.write(bits: 16, value: UInt32(Self.floatToHalfRounded(view.quantisationDenominator)))
        // Raw DCT8 quantisation Modular substream (3 channels of width 8, height 8)
        let quantChannels = (0..<3).map { c in
            Array(view.quantisation[(c * 64)..<((c + 1) * 64)])
        }
        try JPEGBridgeEntropy.writeFlatModularSubstream(
            channels: quantChannels,
            dimensions: [(width: 8, height: 8), (width: 8, height: 8), (width: 8, height: 8)],
            predictor: 1,
            to: &writer,
            policy: policy
        )
        // Tables 1..16: encoding_mode = 0 (kQuantModeLibrary, 3 bits 000 each = 48 zero bits)
        for _ in 1..<17 {
            writer.write(bits: 3, value: 0)
        }

        // num_hf_presets = 1 (encoded as 0 in ceilLog2(numGroups) bits)
        let presetBits = Self.ceilLog2(numGroups)
        if presetBits > 0 {
            writer.write(bits: presetBits, value: 0)
        }
        // used_orders = 0
        try writer.writeU32(
            0,
            distributions: (.literal(0x5F), .literal(0x13), .literal(0), .bits(13))
        )
        // Clustered AC entropy header & codebook, plus encoded group token streams
        let passWriters = try JPEGBridgeEntropy.writeClusteredACStreams(
            groupTokens: groupTokens,
            numContexts: totalACContexts,
            to: &writer,
            policy: policy
        )

        if singleSection {
            writer.alignToByte()
            sectionData.append(writer.finishToData())
        } else {
            writer.alignToByte()
            sectionData.append(writer.finishToData())
            for groupIdx in 0..<numGroups {
                try policy.checkpoint()
                var pw = passWriters[groupIdx]
                pw.alignToByte()
                sectionData.append(pw.finishToData())
            }
        }

        // 3. Assemble outer codestream header + FrameHeader + TOC + sections
        let totalSectionBytes = sectionData.reduce(0) { $0 + $1.count }
        var outer = BitWriter(reservingBytes: totalSectionBytes + 256)
        outer.write(bits: 8, value: 0xFF)
        outer.write(bits: 8, value: 0x0A)
        try SizeHeader(xsize: UInt32(view.frame.width), ysize: UInt32(view.frame.height)).write(to: &outer)

        let isGray = (view.frame.components.count == 1)
        let colorEncoding: ColorEncoding
        if iccProfile != nil {
            colorEncoding = ColorEncoding(
                useICC: true,
                colorSpace: isGray ? .grayscale : .rgb,
                whitePoint: .d65,
                primaries: .srgb,
                transferFunction: .srgb,
                renderingIntent: .relative
            )
        } else if isGray {
            colorEncoding = .grayscaleD65
        } else {
            colorEncoding = .srgb
        }

        let metadata = ImageMetadata(
            allDefault: false,
            orientation: 1,
            intrinsicSize: nil,
            preview: nil,
            animation: nil,
            bitDepth: .standard,
            modular16BitBufferSufficient: true,
            extraChannels: [],
            xybEncoded: false,
            colorEncoding: colorEncoding,
            intensityTarget: 255.0,
            minNits: 0.0,
            relativeToMaxDisplay: false,
            linearBelow: 0.0
        )
        try metadata.write(to: &outer)
        // CustomTransformData: all_default = true (ISO/IEC 18181-1 §6.1)
        outer.writeBit(true)

        if let icc = iccProfile {
            try ICCStream.write(
                icc,
                to: &outer,
                maximumBytes: policy.maximumICCBytes,
                checkpoint: policy.checkpoint
            )
        }
        outer.alignToByte()

        let frameHeader = FrameHeader(
            allDefault: false,
            frameType: .regular,
            encoding: .varDCT,
            flags: FrameFlag.skipAdaptiveDcSmoothing.rawValue,
            colorTransform: view.colourTransform,
            chromaSubsampling: view.chromaSubsampling,
            upsampling: 1,
            extraChannelUpsampling: [],
            groupSizeShift: 1,
            xQmScale: 2,
            bQmScale: 2,
            passes: .default,
            dcLevel: 0,
            customSizeOrOrigin: false,
            frameOrigin: (0, 0),
            frameSize: nil,
            blendingInfo: .default,
            extraChannelBlendingInfo: [],
            animationFrame: .default,
            isLast: true,
            saveAsReference: 0,
            saveBeforeColorTransform: false,
            name: "",
            loopFilter: LoopFilter(allDefault: false, gab: false, epfIters: 0)
        )
        let frameCtx = FrameHeaderContext(
            xybEncoded: false,
            numExtraChannels: 0,
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
            try policy.checkpoint()
            output.append(s)
        }
        guard output.count <= maximumOutputBytes else {
            throw JPEGEntropyError.resourceLimit
        }
        try policy.checkpoint()
        return output
    }

    // MARK: - Helpers

    @inline(__always)
    private static func ceilLog2(_ n: Int) -> Int {
        guard n > 1 else { return 0 }
        return Int.bitWidth - (n - 1).leadingZeroBitCount
    }

    /// IEEE-754 single-precision to binary16 with round-to-nearest-even.
    static func floatToHalfRounded(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exp32 = Int((bits >> 23) & 0xFF)
        let frac32 = bits & 0x007F_FFFF

        if exp32 == 0xFF {
            let frac16 = frac32 != 0 ? UInt16(0x0200) : UInt16(0)
            return sign | 0x7C00 | frac16
        }
        let exp16 = exp32 - (127 - 15)
        if exp16 <= 0 {
            return sign
        }
        if exp16 >= 31 {
            return sign | 0x7C00
        }
        let roundBit: UInt32 = 0x0000_1000
        let tieAdjust = ((frac32 >> 13) & 1) != 0 ? roundBit : (roundBit - 1)
        let rounded = (frac32 | 0x0080_0000) &+ tieAdjust
        var outExp = UInt16(exp16)
        var outFrac = UInt16((rounded >> 13) & 0x03FF)
        if (rounded & 0x0100_0000) != 0 {
            outExp &+= 1
            outFrac = 0
            if outExp >= 31 {
                return sign | 0x7C00
            }
        }
        return sign | (outExp << 10) | outFrac
    }
}
