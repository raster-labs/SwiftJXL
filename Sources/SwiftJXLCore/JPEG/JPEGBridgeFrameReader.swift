// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift Codec/JXLDecoder.swift, JPEG/JXLToJPEGAdapter.swift
// and VarDCT/{QuantEncoding,DequantMatricesDC,QuantizerParams,ColorCorrelationMap}.swift
// at 57e81cb9e2411d1efac435b429a306a031744c1e. JPEG XL Project Authors'
// algorithms retain BSD-3-Clause terms; see Documentation/ThirdParty/libjxl-LICENSE.txt.
import Foundation

package struct JPEGBridgeDecodedFrame: Sendable {
    package let width: Int, height: Int
    package let sampling: [(h: Int, v: Int)]
    package let blocks: [(width: Int, height: Int)]
    package let coefficients: [[Int32]]
    package let quantisation: [[Int32]]

    package func resolve(_ metadata: JBRDBox) throws -> JBRDBox {
        var result = metadata
        guard result.components.count == coefficients.count else { throw JPEGEntropyError.malformed }
        result.width = width; result.height = height
        var assigned = Set<Int>()
        for i in result.components.indices {
            let q = Int(result.components[i].quantIdx)
            guard result.quant.indices.contains(q) else { throw JPEGEntropyError.malformed }
            if assigned.contains(q) {
                guard result.quant[q].values == quantisation[i] else { throw JPEGEntropyError.malformed }
            } else { result.quant[q].values = quantisation[i]; assigned.insert(q) }
            result.components[i].hSampFactor = sampling[i].h
            result.components[i].vSampFactor = sampling[i].v
            result.components[i].widthInBlocks = UInt32(blocks[i].width)
            result.components[i].heightInBlocks = UInt32(blocks[i].height)
        }
        guard assigned.count == result.quant.count else { throw JPEGEntropyError.unsupported }
        return result
    }
}

package enum JPEGBridgeFrameReader {
    package static func read(_ codestream: Data, policy: JPEGBridgePolicy) throws -> JPEGBridgeDecodedFrame {
        try policy.checkpoint()
        guard codestream.count <= 64 * 1024 * 1024, codestream.count <= policy.maximumMemoryBytes / 2 else {
            throw JPEGEntropyError.resourceLimit
        }
        let budget = try ScalarOperationBudget(retainedBytes: codestream.count * 2,
            maximumWorkspaceBytes: policy.maximumMemoryBytes, maximumMemoryBytes: policy.maximumMemoryBytes,
            maximumDecodedBytes: policy.maximumCoefficientBytes, maximumCompressedBytes: max(1, codestream.count),
            deadline: policy.deadline)
        try budget.reserveWorkspace(4 * 1024 * 1024)
        var reader = BridgeFrameReader(r: BitReader(codestream, deadline: policy.deadline,
            maximumNestingDepth: policy.maximumNestingDepth,
            maximumEntropyTableBytes: min(32 * 1024 * 1024, policy.maximumMemoryBytes), budget: budget),
            policy: policy, budget: budget)
        return try reader.read()
    }
}

private struct BridgeModularState {
    let tree: ModularTree
    let header: EntropySectionHeader
    let codebook: MultiClusterCodebook
}

private struct BridgeFrameReader {
    var r: BitReader
    let policy: JPEGBridgePolicy
    let budget: ScalarOperationBudget
    var global: BridgeModularState?
    var starts: [Int] = [], ends: [Int] = []

    private mutating func readTree() throws -> BridgeModularState {
        let header = try EntropySectionHeader.read(from: &r, numContexts: 6)
        let codebook = try MultiClusterCodebook.read(from: &r, header: header)
        var stream = TokenStreamReader(header: header, codebook: codebook)
        let tree = try ModularTree.decode(from: &r, stream: &stream)
        try stream.finish()
        let post = try EntropySectionHeader.read(from: &r, numContexts: tree.leafCount)
        return BridgeModularState(tree: tree, header: post, codebook: try MultiClusterCodebook.read(from: &r, header: post))
    }

    private mutating func modular(_ geometries: [ModularChannelGeometry], group: Int32) throws -> [[Int32]] {
        let header = try GroupHeader.read(from: &r)
        guard header.transforms.isEmpty else { throw JPEGEntropyError.unsupported }
        let state: BridgeModularState
        if header.useGlobalTree {
            guard let global else { throw JPEGEntropyError.malformed }
            state = global
        } else { state = try readTree() }
        var stream = TokenStreamReader(header: state.header, codebook: state.codebook,
            distanceMultiplier: geometries.map(\.width).max() ?? 0)
        let values = try decodeAllChannels(channels: geometries, groupId: group, tree: state.tree,
            stream: &stream, from: &r, wpHeader: header.wpHeader)
        try stream.finish(); try policy.checkpoint()
        return values
    }

    private mutating func begin(_ section: Int) throws {
        try policy.checkpoint()
        if starts.count > 1 { r.seek(toBitPosition: starts[section]) }
    }
    private mutating func end(_ section: Int) throws {
        if starts.count > 1 {
            guard r.position <= ends[section] else { throw JPEGEntropyError.malformed }
            try r.expectZeroPadding()
            guard r.position == ends[section] else { throw JPEGEntropyError.malformed }
        }
    }

    mutating func read() throws -> JPEGBridgeDecodedFrame {
        guard try r.read(bits: 16) == 0x0aff else { throw JPEGEntropyError.malformed }
        let size = try SizeHeader.read(from: &r), width = Int(size.xsize), height = Int(size.ysize)
        guard width > 0, height > 0, width <= 2048, height <= 2048 else { throw JPEGEntropyError.resourceLimit }
        guard width <= policy.maximumDimension, height <= policy.maximumDimension,
              width <= policy.maximumPixels / height else { throw JPEGEntropyError.resourceLimit }
        let metadata = try ImageMetadata.read(from: &r)
        guard !metadata.xybEncoded, metadata.extraChannels.isEmpty, metadata.animation == nil,
              metadata.preview == nil, !metadata.bitDepth.floatingPoint, metadata.bitDepth.bitsPerSample == 8,
              !metadata.colorEncoding.useICC,
              metadata.colorEncoding.colorSpace == .rgb || metadata.colorEncoding.colorSpace == .grayscale else {
            throw JPEGEntropyError.unsupported
        }
        let gray = metadata.colorEncoding.colorSpace == .grayscale
        guard try r.readBit() else { throw JPEGEntropyError.unsupported } // default custom transform data
        try r.expectZeroPadding()
        let frame = try FrameHeader.read(from: &r, context: FrameHeaderContext(xybEncoded: false))
        guard frame.encoding == .varDCT, frame.frameType == .regular, frame.isLast,
              frame.flags == 128, frame.upsampling == 1, frame.passes.numPasses == 1,
              !frame.customSizeOrOrigin, frame.blendingInfo.mode == .replace,
              !frame.loopFilter.gab, frame.loopFilter.epfIters == 0,
              frame.colorTransform == .yCbCr || frame.colorTransform == .none else { throw JPEGEntropyError.unsupported }
        let css = frame.chromaSubsampling
        let bx = ((width + (8 << css.maxHShift) - 1) / (8 << css.maxHShift)) << css.maxHShift
        let by = ((height + (8 << css.maxVShift) - 1) / (8 << css.maxVShift)) << css.maxVShift
        let widths = (0..<3).map { bx >> css.hShift($0) }, heights = (0..<3).map { by >> css.vShift($0) }
        let counts = (0..<3).map { widths[$0] * heights[$0] * 64 }
        let coefficientCount = gray ? counts[1] : counts.reduce(0, +)
        guard coefficientCount <= policy.maximumCoefficientBytes / 4 else { throw JPEGEntropyError.resourceLimit }
        // Final coefficients, capacities, DC/AC metadata, LZ replay and predictor
        // scratch. Entropy tables are charged cumulatively by the shared reader.
        try budget.reserveWorkspace(coefficientCount * 8 + bx * by * 128 + 1024 * 1024)
        let groupSize = 128 << Int(frame.groupSizeShift), groupsX = (width + groupSize - 1) / groupSize
        let groupsY = (height + groupSize - 1) / groupSize, groups = groupsX * groupsY
        guard width <= groupSize * 8, height <= groupSize * 8 else { throw JPEGEntropyError.unsupported }
        let entries = TOC.numEntries(numGroups: groups, numDcGroups: 1, numPasses: 1)
        let toc = try TOC.read(from: &r, numEntries: entries), origin = r.position
        guard let total = toc.offsets.last, total == UInt64(r.bitsRemaining / 8) else { throw JPEGEntropyError.malformed }
        for i in 0..<entries {
            guard toc.offsets[i] <= total, UInt64(toc.entrySizes[i]) <= total - toc.offsets[i] else { throw JPEGEntropyError.malformed }
            starts.append(origin + Int(toc.offsets[i]) * 8)
            ends.append(starts[i] + Int(toc.entrySizes[i]) * 8)
        }
        try begin(0)
        let defaultDC = try r.readBit()
        var dcScales = [Float](repeating: 1 / 128, count: 3)
        if !defaultDC {
            for c in 0..<3 {
                dcScales[c] = halfToFloat(UInt16(try r.read(bits: 16))) / 128
                guard dcScales[c].isFinite, dcScales[c] > 1e-8 else { throw JPEGEntropyError.malformed }
            }
        }
        let globalScale = try r.readU32((.offset(constant: 1, extraBits: 11), .offset(constant: 2049, extraBits: 11),
            .offset(constant: 4097, extraBits: 12), .offset(constant: 8193, extraBits: 16)))
        let quantDC = try r.readU32((.literal(16), .offset(constant: 1, extraBits: 5),
            .offset(constant: 1, extraBits: 8), .offset(constant: 1, extraBits: 16)))
        guard globalScale == 65536, quantDC == 1 else { throw JPEGEntropyError.unsupported }
        let contexts = try JPEGBridgeBlockContext.read(from: &r)
        // The JPEG coefficient fingerprint uses explicit zero base/DC correlations.
        guard try !r.readBit() else { throw JPEGEntropyError.unsupported }
        let factor = try r.readU32((.literal(84), .literal(256), .offset(constant: 2, extraBits: 8), .offset(constant: 258, extraBits: 16)))
        let baseX = halfToFloat(UInt16(try r.read(bits: 16))), baseB = halfToFloat(UInt16(try r.read(bits: 16)))
        let dcX = try r.read(bits: 8), dcB = try r.read(bits: 8)
        guard factor == 84, baseX == 0, baseB == 0, dcX == 128, dcB == 128 else { throw JPEGEntropyError.unsupported }
        if try r.readBit() { global = try readTree() }
        try end(0); try begin(1)
        guard try r.read(bits: 2) == 0 else { throw JPEGEntropyError.unsupported }
        let dcStorage = try modular([1, 0, 2].map { ModularChannelGeometry(width: widths[$0], height: heights[$0]) }, group: 1)
        let dc = [dcStorage[1], dcStorage[0], dcStorage[2]]
        let metaBits = Int(ceilLog2(UInt32(bx * by)))
        let metaCount = Int(try r.read(bits: metaBits)) + 1
        guard metaCount == bx * by else { throw JPEGEntropyError.unsupported } // DCT8 only
        let tileWidth = (bx + 7) / 8, tileHeight = (by + 7) / 8
        let acMeta = try modular([.init(width: tileWidth, height: tileHeight), .init(width: tileWidth, height: tileHeight),
            .init(width: metaCount, height: 2), .init(width: bx, height: by)], group: 3)
        guard acMeta[2].prefix(metaCount).allSatisfy({ $0 == 0 }) else { throw JPEGEntropyError.unsupported }
        let quantFields = Array(acMeta[2].suffix(metaCount)).map { Int64($0) + 1 }
        guard quantFields.allSatisfy({ $0 > 0 && $0 <= Int64(UInt32.max) }),
              acMeta[0].allSatisfy({ (-128...127).contains($0) }), acMeta[1].allSatisfy({ (-128...127).contains($0) }) else {
            throw JPEGEntropyError.malformed
        }
        try end(1); try begin(2)
        guard try !r.readBit() else { throw JPEGEntropyError.unsupported }
        var quant: [[Int32]] = []
        for slot in 0..<17 {
            let mode = try r.read(bits: 3)
            if slot == 0 {
                guard mode == 7 else { throw JPEGEntropyError.unsupported }
                let denominator = halfToFloat(UInt16(try r.read(bits: 16)))
                guard abs(denominator - Float(1.0 / 2040)) < 1e-8 else { throw JPEGEntropyError.unsupported }
                quant = try modular([.init(width: 8, height: 8), .init(width: 8, height: 8), .init(width: 8, height: 8)], group: 4)
                guard quant.allSatisfy({ $0.allSatisfy({ (1...65535).contains($0) }) }) else { throw JPEGEntropyError.malformed }
            } else { guard mode == 0 else { throw JPEGEntropyError.unsupported } }
        }
        let histogramBits = Int(ceilLog2(UInt32(groups)))
        let histograms = 1 + Int(try r.read(bits: histogramBits))
        guard histograms <= groups else { throw JPEGEntropyError.malformed }
        let orders = try readJPEGBridgeOrders(from: &r)
        let acHeader = try EntropySectionHeader.read(from: &r, numContexts: histograms * contexts.contexts,
            maximumContexts: 64 * 16 * 495)
        let acCodebook = try MultiClusterCodebook.read(from: &r, header: acHeader)
        try end(2)
        var planes = (0..<3).map { [Int32](repeating: 0, count: gray && $0 != 1 ? 0 : counts[$0]) }
        for c in 0..<3 {
            let expectedScale = halfToFloat(floatToHalf(128 / (2040 / Float(quant[c][0])))) / 128
            guard dcScales[c] == expectedScale else { throw JPEGEntropyError.unsupported }
            if gray && c != 1 {
                guard dc[c].allSatisfy({ $0 == 0 }) else { throw JPEGEntropyError.malformed }
                continue
            }
            let offset: Int32 = frame.colorTransform == .none ? 1024 / quant[c][0] : 0
            for i in dc[c].indices {
                let (value, overflow) = dc[c][i].subtractingReportingOverflow(offset)
                guard !overflow else { throw JPEGEntropyError.malformed }
                planes[c][i * 64] = value
            }
        }
        let blocksPerGroup = groupSize / 8
        var block = [Int32](repeating: 0, count: 64)
        for group in 0..<groups {
            try begin(3 + group)
            let histogram = Int(try r.read(bits: Int(ceilLog2(UInt32(histograms)))))
            guard histogram < histograms else { throw JPEGEntropyError.malformed }
            var stream = TokenStreamReader(header: acHeader, codebook: acCodebook)
            let x0 = (group % groupsX) * blocksPerGroup, y0 = (group / groupsX) * blocksPerGroup
            let w = min(blocksPerGroup, bx - x0), h = min(blocksPerGroup, by - y0)
            let groupWidths = (0..<3).map { (w + (1 << css.hShift($0)) - 1) >> css.hShift($0) }
            var nonzero = (0..<3).map { [Int32](repeating: 0, count: groupWidths[$0] * ((h + (1 << css.vShift($0)) - 1) >> css.vShift($0))) }
            for y in 0..<h {
                try policy.checkpoint()
                for x in 0..<w {
                    let dcValues = (0..<3).map { dc[$0][((y0 + y) >> css.vShift($0)) * widths[$0] + ((x0 + x) >> css.hShift($0))] }
                    for c in [1, 0, 2] {
                        let hs = css.hShift(c), vs = css.vShift(c)
                        if x % (1 << hs) != 0 || y % (1 << vs) != 0 { continue }
                        let cx = x >> hs, cy = y >> vs, stride = groupWidths[c]
                        let prediction: UInt32 = cy == 0 ? (cx == 0 ? 32 : UInt32(nonzero[c][cx - 1]))
                            : (cx == 0 ? UInt32(nonzero[c][(cy - 1) * stride])
                               : UInt32((nonzero[c][(cy - 1) * stride + cx] + nonzero[c][cy * stride + cx - 1] + 1) / 2))
                        let context = try contexts.blockContext(dcValues: dcValues,
                            quantisation: UInt32(quantFields[(y0 + y) * bx + x0 + x]), channel: c)
                        let nnz = try contexts.readBlock(prediction: prediction, blockContext: context,
                            offset: histogram * contexts.contexts, order: orders[c], stream: &stream, from: &r, into: &block)
                        nonzero[c][cy * stride + cx] = Int32(nnz)
                        if gray && c != 1 {
                            guard nnz == 0 else { throw JPEGEntropyError.malformed }
                            continue
                        }
                        let destination = (((y0 + y) >> vs) * widths[c] + ((x0 + x) >> hs)) * 64
                        for row in 0..<8 {
                            for column in 0..<8 where row != 0 || column != 0 {
                                planes[c][destination + row * 8 + column] = block[column * 8 + row]
                            }
                        }
                    }
                }
            }
            try stream.finish(); try end(3 + group)
        }
        if entries == 1 { try r.expectZeroPadding(); guard r.position == ends[0] else { throw JPEGEntropyError.malformed } }
        if css.maxHShift == 0, css.maxVShift == 0, !gray, frame.colorTransform == .yCbCr {
            for c in [0, 2] {
                let map = acMeta[c == 0 ? 0 : 1]
                for y in 0..<by {
                    try policy.checkpoint()
                    for x in 0..<bx {
                        let scale = Int64(map[(y / 8) * tileWidth + x / 8]) * 2048 / 84
                        for k in 1..<64 {
                            let transposed = (k % 8) * 8 + k / 8
                            let ratio = Int64(quant[1][transposed]) * 2048 / Int64(quant[c][transposed])
                            let factor = (scale * ratio + 1024) >> 11
                            let index = (y * bx + x) * 64 + k
                            let restored = Int64(planes[c][index]) + ((Int64(planes[1][index]) * factor + 1024) >> 11)
                            guard let value = Int32(exactly: restored) else { throw JPEGEntropyError.malformed }
                            planes[c][index] = value
                        }
                    }
                }
            }
        }
        let order = gray ? [1] : (frame.colorTransform == .yCbCr ? [1, 0, 2] : [0, 1, 2])
        let modes = [Int(css.channelModes.0), Int(css.channelModes.1), Int(css.channelModes.2)]
        let hshift = [0, 1, 1, 0], vshift = [0, 1, 0, 1]
        let sampling = order.map { (h: 1 << hshift[modes[$0]], v: 1 << vshift[modes[$0]]) }
        let quantisation = order.map { c in (0..<64).map { quant[c][($0 % 8) * 8 + $0 / 8] } }
        try policy.checkpoint()
        return JPEGBridgeDecodedFrame(width: width, height: height, sampling: sampling,
            blocks: order.map { (width: widths[$0], height: heights[$0]) }, coefficients: order.map { planes[$0] }, quantisation: quantisation)
    }
}
