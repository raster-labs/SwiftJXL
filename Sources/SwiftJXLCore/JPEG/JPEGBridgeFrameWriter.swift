// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift Codec/VarDCTBitstreamWriter.swift,
// JPEG/JXLBridgeEncoder.swift, Modular/ModularSubImage.swift and
// VarDCT/{ACDecoder,QuantEncodingBitstream,DequantMatricesDC,QuantizerParams}.swift
// at 57e81cb9e2411d1efac435b429a306a031744c1e.
// JPEG XL Project Authors' algorithms retain BSD-3-Clause attribution.
// See Documentation/ThirdParty/libjxl-LICENSE.txt.
import Foundation

/// Writes the predecessor's single-DC-group, multi-AC-group JPEG bridge profile.
/// Streaming histogram passes use fixed workspace instead of frame-sized token
/// lists. Multi-group colour AC data may use compact single-cluster ANS when its
/// measured bit cost beats prefix coding, including conservative framing costs.
package enum JPEGBridgeFrameWriter {
    package static func write(_ coefficients: JPEGBridgeCoefficients,
                              maximumOutputBytes: Int = 64 * 1024 * 1024, iccProfile: Data? = nil,
                              policy: JPEGBridgePolicy) throws -> Data {
        try policy.checkpoint()
        let frame = coefficients.frame
        guard frame.width <= 2048, frame.height <= 2048 else { throw JPEGEntropyError.unsupported }
        guard (iccProfile?.count ?? 0) <= policy.maximumICCBytes else { throw JPEGEntropyError.resourceLimit }
        let scratch = 4 * 1024 * 1024 + (iccProfile?.count ?? 0) * 8 + 65536
        guard maximumOutputBytes > 0, frame.coefficientCount <= policy.maximumCoefficientBytes / 4,
              coefficients.admittedBytes <= policy.maximumMemoryBytes,
              scratch < policy.maximumMemoryBytes - coefficients.admittedBytes else {
            throw JPEGEntropyError.resourceLimit
        }
        let limit = min(maximumOutputBytes, (policy.maximumMemoryBytes - coefficients.admittedBytes - scratch) / 6)
        guard limit > 0 else { throw JPEGEntropyError.resourceLimit }
        let budget = try ScalarOperationBudget(retainedBytes: coefficients.admittedBytes,
            maximumWorkspaceBytes: policy.maximumMemoryBytes, maximumMemoryBytes: policy.maximumMemoryBytes,
            maximumDecodedBytes: 1, maximumCompressedBytes: limit, deadline: policy.deadline)
        try budget.reserveWorkspace(scratch + limit * 6)
        let work = ScalarEncodingWork(budget: budget, writerByteLimit: limit)
        return try ScalarEncodingWork.$current.withValue(work) {
            let writer = BridgeFrameWriter(view: coefficients, policy: policy, limit: limit, iccProfile: iccProfile)
            let result = try writer.write()
            try work.checkpoint(); try policy.checkpoint()
            return result
        }
    }
}

private struct BridgePrefix {
    let header: EntropySectionHeader
    let codebook: MultiClusterCodebook
    init(histogram: [Int], contexts: Int) throws {
        let size = max(2, (histogram.lastIndex(where: { $0 != 0 }) ?? 0) + 1)
        var counts = Array(histogram.prefix(size))
        if counts.filter({ $0 != 0 }).count == 1 {
            counts[counts[0] == 0 ? 0 : 1] = 1
        }
        let lengths = lengthLimitedCanonicalHuffman(counts: counts, maxLength: 15, alphabetSize: size)
        codebook = MultiClusterCodebook(huffmanTables: [try PrefixCodeTable(lengths: lengths)],
            ansCounts: [], alphabetSizes: [size])
        header = EntropySectionHeader(lz77: .disabled, contextMap: .trivial(numContexts: contexts),
            usePrefixCode: true, logAlphaSize: 15, uintConfigs: [.raw4])
    }
    init(ansHistogram histogram: [Int], contexts: Int) throws {
        let size = max(2, (histogram.lastIndex(where: { $0 != 0 }) ?? 0) + 1)
        let counts = histogram.prefix(size).map { UInt32($0) }
        let distribution = try ANSDistribution(rawFrequencies: counts)
        var scratch = BitWriter()
        let wire = try SpecANSDistribution.writeHistogram(
            distribution.frequencies.map { Int32($0) }, to: &scratch)
        let logAlpha = max(5, Int(ceilLog2(UInt32(wire.count))))
        codebook = MultiClusterCodebook(huffmanTables: [], ansCounts: [wire], alphabetSizes: [wire.count])
        header = EntropySectionHeader(lz77: .disabled, contextMap: .trivial(numContexts: contexts),
            usePrefixCode: false, logAlphaSize: logAlpha, uintConfigs: [.raw4])
    }
    func writeHeader(to writer: inout BitWriter, contexts: Int) throws {
        try header.write(to: &writer, numContexts: contexts)
        try codebook.write(to: &writer, header: header)
    }
    func write(_ value: UInt32, to writer: inout BitWriter) throws {
        try TokenStreamWriter(header: header, codebook: codebook).writeToken(context: 0, value: value, to: &writer)
    }
}

private struct BridgeFrameWriter {
    let view: JPEGBridgeCoefficients
    let policy: JPEGBridgePolicy
    let limit: Int
    let iccProfile: Data?
    private var blocksX: Int { view.frame.components[0].paddedBlocksWide }
    private var blocksY: Int { view.frame.components[0].paddedBlocksHigh }
    private var groupsX: Int { (view.frame.width + 255) / 256 }
    private var groupsY: Int { (view.frame.height + 255) / 256 }
    private var metadataZeros: Int { 2 * ((blocksX + 7) / 8) * ((blocksY + 7) / 8) + 3 * blocksX * blocksY }
    private static let order = [0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,
        12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28,35,42,49,56,
        57,50,43,36,29,22,15,23,30,37,44,51,58,59,52,45,38,31,39,46,
        53,60,61,54,47,55,62,63]

    func write() throws -> Data {
        var dcHistogram = [Int](repeating: 0, count: HybridUintConfig.raw4.maxToken + 1)
        try dcTokens { dcHistogram[Int(HybridUintConfig.raw4.encode($0).token)] += 1 }
        dcHistogram[0] += metadataZeros
        let dc = try BridgePrefix(histogram: dcHistogram, contexts: 1)
        var acHistogram = [Int](repeating: 0, count: HybridUintConfig.raw4.maxToken + 1)
        for group in 0..<(groupsX * groupsY) {
            try acTokens(group: group) { acHistogram[Int(HybridUintConfig.raw4.encode($0).token)] += 1 }
        }
        let ac = try acCode(histogram: acHistogram)
        var sections: [Data] = []
        var sectionBytes = 0
        func section(_ body: (inout BitWriter) throws -> Void) throws {
            var writer = BitWriter()
            try body(&writer)
            let data = writer.finishToData()
            try ScalarEncodingWork.checkpoint(); try policy.checkpoint()
            guard data.count <= limit - sectionBytes else { throw JPEGEntropyError.resourceLimit }
            sectionBytes += data.count; sections.append(data)
        }
        if groupsX * groupsY == 1 {
            try section { w in
                try lfGlobal(dc, to: &w); try dcGroup(dc, to: &w)
                try hfGlobal(ac, to: &w); try acGroup(ac, group: 0, to: &w)
            }
        } else {
            try section { try lfGlobal(dc, to: &$0) }
            try section { try dcGroup(dc, to: &$0) }
            try section { try hfGlobal(ac, to: &$0) }
            for group in 0..<(groupsX * groupsY) {
                try section { w in try acGroup(ac, group: group, to: &w) }
            }
        }
        var output = BitWriter()
        try imageHeader(to: &output); try frameHeader(to: &output)
        let sizes = sections.map { UInt32($0.count) }
        var offsets: [UInt64] = [0]
        for size in sizes { offsets.append((offsets.last ?? 0) + UInt64(size)) }
        try TOC(hasPermutation: false, entrySizes: sizes, offsets: offsets).write(to: &output)
        output.alignToByte()
        for section in sections {
            try policy.checkpoint()
            guard section.count <= limit - output.bytes.count else { throw JPEGEntropyError.resourceLimit }
            // Bound copy/cancellation intervals even for large AC sections.
            var start = 0
            while start < section.count {
                try policy.checkpoint()
                let end = min(section.count, start + 4096)
                output.appendBytes(Data(section[start..<end])); start = end
            }
        }
        try ScalarEncodingWork.checkpoint()
        return output.finishToData()
    }

    private func dcTokens(_ emit: (UInt32) throws -> Void) throws {
        for channel in [1, 0, 2] {
            let shape = view.channels[channel], width = shape.blocksWide
            var previous = [Int32](repeating: 0, count: width)
            var current = previous
            for y in 0..<shape.blocksHigh {
                try policy.checkpoint()
                for x in 0..<width {
                    let value = try view.dc(channel: channel, block: y * width + x)
                    let west = x > 0 ? current[x - 1] : (y > 0 ? previous[x] : 0)
                    let north = y > 0 ? previous[x] : west
                    let northwest = x > 0 && y > 0 ? previous[x - 1] : (x > 0 ? west : north)
                    let prediction = min(max(west &+ north &- northwest, min(west, north)), max(west, north))
                    try emit(ZigZag.pack(value &- prediction)); current[x] = value
                }
                swap(&current, &previous)
            }
        }
    }

    private func acCode(histogram: [Int]) throws -> BridgePrefix {
        let prefix = try BridgePrefix(histogram: histogram, contexts: 15 * (37 + 458))
        // Measured setup/replay work regresses greyscale, small or flat groups.
        // Keep their original bytes and latency; only cost substantial streams.
        guard view.frame.components.count == 3, groupsX * groupsY > 1,
              histogram.reduce(0, +) >= 16_384,
              histogram.filter({ $0 > 0 }).count > 1 else { return prefix }
        let ans = try BridgePrefix(ansHistogram: histogram, contexts: 15 * (37 + 458))
        var prefixHeader = BitWriter(), ansHeader = BitWriter()
        try prefix.writeHeader(to: &prefixHeader, contexts: 15 * (37 + 458))
        try ans.writeHeader(to: &ansHeader, contexts: 15 * (37 + 458))
        var prefixBits = prefixHeader.bitCount, ansBits = ansHeader.bitCount
        let stream = try ANSTokenStreamWriter(header: ans.header, codebook: ans.codebook)
        for group in 0..<(groupsX * groupsY) {
            // Costing retains only UInt16 symbols for one group (<= 384 KiB).
            var symbols: [UInt16] = []
            symbols.reserveCapacity(3 * 32 * 32 * 64)
            try acTokens(group: group) { value in
                let symbol = Int(HybridUintConfig.raw4.tokenOnly(value))
                symbols.append(UInt16(symbol))
                prefixBits += Int(prefix.codebook.huffmanTables[0].lengths[symbol])
            }
            ansBits += 32 + 16 * (try stream.refillWordCount(symbols: symbols))
            try policy.checkpoint()
        }
        // Extra bits are identical. Allow 8 bits of section padding and a
        // full 32-bit TOC entry per changed AC/HFGlobal section. This exceeds
        // every possible framing increase; no size regression is selected.
        return ansBits + 40 * (groupsX * groupsY + 1) < prefixBits ? ans : prefix
    }

    private func acGroup(_ code: BridgePrefix, group: Int, to writer: inout BitWriter) throws {
        if code.header.usePrefixCode {
            try acTokens(group: group) { try code.write($0, to: &writer) }
        } else {
            // At most 196608 symbols (384 KiB), reused for refills, plus
            // 24 KiB flags. This fits the existing 4 MiB scratch admission.
            var symbols: [UInt16] = []
            symbols.reserveCapacity(3 * 32 * 32 * 64)
            try acTokens(group: group) { symbols.append(UInt16(HybridUintConfig.raw4.tokenOnly($0))) }
            let stream = try ANSTokenStreamWriter(header: code.header, codebook: code.codebook)
            try stream.finishSingleCluster(symbols: &symbols,
                replay: { try acTokens(group: group, $0) }, to: &writer)
        }
    }

    private func acTokens(group: Int, _ emit: (UInt32) throws -> Void) throws {
        let x0 = (group % groupsX) * 32, y0 = (group / groupsX) * 32
        let width = min(32, blocksX - x0), height = min(32, blocksY - y0)
        var block = [Int32](repeating: 0, count: 64)
        for y in 0..<height {
            try policy.checkpoint()
            for x in 0..<width {
                for channel in [1, 0, 2] {
                    let hs = view.chromaSubsampling.hShift(channel), vs = view.chromaSubsampling.vShift(channel)
                    if x % (1 << hs) != 0 || y % (1 << vs) != 0 { continue }
                    let index = ((y0 + y) >> vs) * view.channels[channel].blocksWide + ((x0 + x) >> hs)
                    try view.readBlock(channel: channel, block: index, into: &block)
                    var nonzeros = 0
                    for k in 1..<64 where block[Self.order[k]] != 0 { nonzeros += 1 }
                    try emit(UInt32(nonzeros))
                    for k in 1..<64 {
                        if nonzeros == 0 { break }
                        let value = block[Self.order[k]]
                        try emit(ZigZag.pack(value))
                        if value != 0 { nonzeros -= 1 }
                    }
                }
            }
        }
    }

    private func tree(to writer: inout BitWriter) throws {
        let code = MultiClusterCodebook(huffmanTables: [try PrefixCodeTable(lengths: [UInt8](repeating: 4, count: 16))],
            ansCounts: [], alphabetSizes: [16])
        let header = EntropySectionHeader(lz77: .disabled, contextMap: .trivial(numContexts: 6),
            usePrefixCode: true, logAlphaSize: 15,
            uintConfigs: [HybridUintConfig(splitExponent: 0, msbInToken: 0, lsbInToken: 0)])
        try header.write(to: &writer, numContexts: 6); try code.write(to: &writer, header: header)
        let tree = ModularTree(nodes: [ModularTreeNode(property: -1, splitVal: 0, leftChildOrLeafId: 0,
            rightChild: 0, predictor: .gradient, predictorOffset: 0, multiplier: 1, rawPredictor: 5)])
        let tokens = TokenStreamWriter(header: header, codebook: code)
        try tree.encode { try tokens.writeToken(context: $0, value: $1, to: &writer) }
    }

    private func lfGlobal(_ code: BridgePrefix, to writer: inout BitWriter) throws {
        writer.writeBit(false)
        for scale in view.dcQuantisation { writer.write(bits: 16, value: UInt32(floatToHalf(128 / scale))) }
        try writer.writeU32(65536, distributions: (.offset(constant: 1, extraBits: 11), .offset(constant: 2049, extraBits: 11),
            .offset(constant: 4097, extraBits: 12), .offset(constant: 8193, extraBits: 16)))
        try writer.writeU32(1, distributions: (.literal(16), .offset(constant: 1, extraBits: 5),
            .offset(constant: 1, extraBits: 8), .offset(constant: 1, extraBits: 16)))
        writer.writeBit(true) // default block-context map
        writer.writeBit(false) // explicit zero colour correlations
        try writer.writeU32(84, distributions: (.literal(84), .literal(256),
            .offset(constant: 2, extraBits: 8), .offset(constant: 258, extraBits: 16)))
        writer.write(bits: 16, value: 0); writer.write(bits: 16, value: 0)
        writer.write(bits: 8, value: 128); writer.write(bits: 8, value: 128)
        writer.writeBit(true) // global modular tree present
        try tree(to: &writer); try code.writeHeader(to: &writer, contexts: 1)
    }

    private func dcGroup(_ code: BridgePrefix, to writer: inout BitWriter) throws {
        writer.write(bits: 2, value: 0)
        try GroupHeader.default.write(to: &writer)
        try dcTokens { try code.write($0, to: &writer) }
        let blocks = blocksX * blocksY, bits = Int(ceilLog2(UInt32(blocks)))
        if bits > 0 { writer.write(bits: bits, value: UInt32(blocks - 1)) }
        try GroupHeader.default.write(to: &writer)
        for i in 0..<metadataZeros {
            if i & 1023 == 0 { try policy.checkpoint() }
            try code.write(0, to: &writer)
        }
    }

    private func hfGlobal(_ code: BridgePrefix, to writer: inout BitWriter) throws {
        writer.writeBit(false) // custom dequantisation
        writer.write(bits: 3, value: 7) // RAW DCT8 quantisation
        writer.write(bits: 16, value: UInt32(floatToHalf(view.quantisationDenominator)))
        try GroupHeader(useGlobalTree: false, wpHeader: .default, transforms: []).write(to: &writer)
        try tree(to: &writer)
        var residuals: [UInt32] = [], histogram = [Int](repeating: 0, count: HybridUintConfig.raw4.maxToken + 1)
        residuals.reserveCapacity(192)
        for c in 0..<3 {
            let plane = Array(view.quantisation[(c * 64)..<(c * 64 + 64)])
            for y in 0..<8 {
                for x in 0..<8 {
                    let prediction = Predictor.gradient.apply(to: Neighbourhood(at: x, y, in: plane, width: 8))
                    let value = ZigZag.pack(plane[y * 8 + x] &- prediction)
                    residuals.append(value); histogram[Int(HybridUintConfig.raw4.encode(value).token)] += 1
                }
            }
        }
        let quant = try BridgePrefix(histogram: histogram, contexts: 1)
        try quant.writeHeader(to: &writer, contexts: 1)
        for value in residuals { try quant.write(value, to: &writer) }
        for _ in 1..<17 { writer.write(bits: 3, value: 0) } // library matrices
        let bits = Int(ceilLog2(UInt32(groupsX * groupsY)))
        if bits > 0 { writer.write(bits: bits, value: 0) } // one histogram per pass
        try writer.writeU32(0, distributions: (.literal(0x5F), .literal(0x13), .literal(0), .bits(13)))
        try code.writeHeader(to: &writer, contexts: 15 * (37 + 458))
    }

    private func imageHeader(to writer: inout BitWriter) throws {
        writer.write(bits: 8, value: 0xff); writer.write(bits: 8, value: 0x0a)
        try SizeHeader(xsize: UInt32(view.frame.width), ysize: UInt32(view.frame.height)).write(to: &writer)
        let colour = iccProfile == nil ? (view.frame.components.count == 1 ? ColorEncoding.grayscaleD65 : .srgb)
            : ColorEncoding(useICC: true, colorSpace: view.frame.components.count == 1 ? .grayscale : .rgb,
                whitePoint: nil, primaries: nil, transferFunction: .unknown, renderingIntent: .relative)
        let metadata = ImageMetadata(allDefault: false, orientation: 1, intrinsicSize: nil, preview: nil, animation: nil,
            bitDepth: BitDepth(floatingPoint: false, bitsPerSample: 8), modular16BitBufferSufficient: true,
            extraChannels: [], xybEncoded: false, colorEncoding: colour,
            intensityTarget: 255, minNits: 0, relativeToMaxDisplay: false, linearBelow: 0)
        try metadata.write(to: &writer); writer.writeBit(true)
        if let iccProfile { try ICCStream.write(iccProfile, to: &writer, maximumBytes: policy.maximumICCBytes, checkpoint: policy.checkpoint) }
        writer.alignToByte()
    }

    private func frameHeader(to writer: inout BitWriter) throws {
        let header = FrameHeader(allDefault: false, frameType: .regular, encoding: .varDCT, flags: 128,
            colorTransform: view.colourTransform, chromaSubsampling: view.chromaSubsampling,
            upsampling: 1, extraChannelUpsampling: [], groupSizeShift: 1, xQmScale: 2, bQmScale: 2,
            passes: .default, dcLevel: 0, customSizeOrOrigin: false, frameOrigin: (0, 0), frameSize: nil,
            blendingInfo: .default, extraChannelBlendingInfo: [], animationFrame: .default, isLast: true,
            saveAsReference: 0, saveBeforeColorTransform: false, name: "",
            loopFilter: LoopFilter(allDefault: false, gab: false, epfIters: 0))
        try header.write(to: &writer, context: FrameHeaderContext(xybEncoded: false, numExtraChannels: 0,
            haveAnimation: false, haveTimecodes: false))
    }
}
