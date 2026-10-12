// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Codec/VarDCTBitstreamWriter.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e. Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause; see libjxl-LICENSE.txt.
import Foundation

private struct VarDCTPrefix {
    let header: EntropySectionHeader
    let codebook: MultiClusterCodebook
    init(histogram: [Int], contexts: Int) throws {
        let size = max(2, (histogram.lastIndex(where: { $0 != 0 }) ?? 0) + 1)
        var counts = Array(histogram.prefix(size))
        if counts.filter({ $0 != 0 }).count == 1 { counts[counts[0] == 0 ? 0 : 1] = 1 }
        let lengths = lengthLimitedCanonicalHuffman(counts: counts, maxLength: 15, alphabetSize: size)
        codebook = MultiClusterCodebook(huffmanTables: [try PrefixCodeTable(lengths: lengths)],
            ansCounts: [], alphabetSizes: [size])
        header = EntropySectionHeader(lz77: .disabled, contextMap: .trivial(numContexts: contexts),
            usePrefixCode: true, logAlphaSize: 15, uintConfigs: [.raw4])
    }
    func writeHeader(to writer: inout BitWriter, contexts: Int) throws {
        try header.write(to: &writer, numContexts: contexts)
        try codebook.write(to: &writer, header: header)
    }
    func write(_ value: UInt32, to writer: inout BitWriter) throws {
        try TokenStreamWriter(header: header, codebook: codebook).writeToken(context: 0, value: value, to: &writer)
    }
}

/// Bounded DC/AC groups with standard prefix entropy. Histogram
/// passes stream tokens instead of retaining frame-sized token arrays. The
/// source borrow is local to the synchronous encoder call, never retained.
struct VarDCTFrameWriter {
    let coefficients: VarDCTPixelEncoder.Coefficients
    let source: VarDCTBorrowedSource
    let budget: ScalarOperationBudget
    let limit: Int
    private var groupsX: Int { (coefficients.width + 255) / 256 }
    private var groupsY: Int { (coefficients.height + 255) / 256 }
    private var dcGroupsX: Int { (coefficients.blocksX + 255) / 256 }
    private var dcGroupsY: Int { (coefficients.blocksY + 255) / 256 }
    private var dcGroups: Int { dcGroupsX * dcGroupsY }
    private func dcRegion(_ group: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let x = group % dcGroupsX * 256, y = group / dcGroupsX * 256
        return (x, y, min(256, coefficients.blocksX - x), min(256, coefficients.blocksY - y))
    }
    private func transformIndices(_ group: Int) throws -> [Int] {
        let region = dcRegion(group)
        try budget.reserveWorkspace(ScalarOperationBudget.product(region.width * region.height, 16))
        if let transforms = coefficients.transforms {
            return transforms.indices.filter { i in
                let t = transforms[i]
                return t.x >= region.x && t.x < region.x + region.width &&
                    t.y >= region.y && t.y < region.y + region.height
            }
        }
        var indices: [Int] = []
        indices.reserveCapacity(region.width * region.height)
        for y in 0..<region.height { for x in 0..<region.width {
            indices.append((region.y + y) * coefficients.blocksX + region.x + x)
        } }
        return indices
    }
    static let order = [0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,
        12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28,35,42,49,56,
        57,50,43,36,29,22,15,23,30,37,44,51,58,59,52,45,38,31,39,46,
        53,60,61,54,47,55,62,63]

    func write() throws -> Data {
        var modularHistogram = [Int](repeating: 0, count: HybridUintConfig.raw4.maxToken + 1)
        for group in 0..<(groupsX * groupsY) {
            try alphaTokens(group: group) { modularHistogram[Int(HybridUintConfig.raw4.encode($0).token)] += 1 }
        }
        for group in 0..<dcGroups {
            try dcTokens(group: group) { modularHistogram[Int(HybridUintConfig.raw4.encode($0).token)] += 1 }
            try metadataTokens(group: group, indices: transformIndices(group)) {
                modularHistogram[Int(HybridUintConfig.raw4.encode($0).token)] += 1
            }
        }
        let modular = try VarDCTPrefix(histogram: modularHistogram, contexts: 1)
        var acHistogram = [Int](repeating: 0, count: HybridUintConfig.raw4.maxToken + 1)
        for group in 0..<(groupsX * groupsY) {
            try acTokens(group: group) { acHistogram[Int(HybridUintConfig.raw4.encode($0).token)] += 1 }
        }
        let ac = try VarDCTPrefix(histogram: acHistogram, contexts: 15 * 495)
        var sections: [Data] = [], sectionBytes = 0
        func section(_ body: (inout BitWriter) throws -> Void) throws {
            var writer = BitWriter()
            try body(&writer); writer.alignToByte()
            let data = writer.finishToData()
            try ScalarEncodingWork.checkpoint()
            guard data.count <= limit - sectionBytes else { throw ScalarModularError.resourceLimit }
            sectionBytes += data.count; sections.append(data)
        }
        if groupsX * groupsY == 1 {
            try section { writer in
                try lfGlobal(modular, to: &writer); try dcGroup(0, modular, to: &writer)
                try hfGlobal(ac, to: &writer)
                try acTokens(group: 0) { try ac.write($0, to: &writer) }
            }
        } else {
            try section { try lfGlobal(modular, to: &$0) }
            for group in 0..<dcGroups { try section { try dcGroup(group, modular, to: &$0) } }
            try section { try hfGlobal(ac, to: &$0) }
            for group in 0..<(groupsX * groupsY) {
                try section { writer in
                    try acTokens(group: group) { try ac.write($0, to: &writer) }
                    if coefficients.hasAlpha {
                        try GroupHeader.default.write(to: &writer)
                        try alphaTokens(group: group) { try modular.write($0, to: &writer) }
                    }
                }
            }
        }
        var writer = BitWriter()
        try imageHeader(to: &writer); try frameHeader(to: &writer)
        let sizes = sections.map { UInt32($0.count) }
        var offsets: [UInt64] = [0]
        for size in sizes { offsets.append((offsets.last ?? 0) + UInt64(size)) }
        try TOC(hasPermutation: false, entrySizes: sizes, offsets: offsets).write(to: &writer)
        writer.alignToByte()
        for data in sections {
            guard data.count <= limit - writer.bytes.count else { throw ScalarModularError.resourceLimit }
            var start = 0
            while start < data.count {
                try budget.checkpoint()
                let end = min(data.count, start + 4096)
                writer.appendBytes(Data(data[start..<end])); start = end
            }
        }
        try ScalarEncodingWork.checkpoint()
        return writer.finishToData()
    }

    private func modularTokens(width: Int, height: Int, value: (Int) throws -> Int32,
                               emit: (UInt32) throws -> Void) throws {
        for y in 0..<height { for x in 0..<width {
            if x & 255 == 0 { try budget.checkpoint() }
            let i = y * width + x, sample = try value(i)
            let west = try x > 0 ? value(i - 1) : (y > 0 ? value(i - width) : 0)
            let north = try y > 0 ? value(i - width) : west
            let northwest = try x > 0 && y > 0 ? value(i - width - 1) : (x > 0 ? west : north)
            let prediction = min(max(west &+ north &- northwest, min(west, north)), max(west, north))
            try emit(ZigZag.pack(sample &- prediction))
        } }
    }
    private func alphaTokens(group: Int, _ emit: (UInt32) throws -> Void) throws {
        guard coefficients.hasAlpha else { return }
        let x = group % groupsX * 256, y = group / groupsX * 256
        let width = min(256, coefficients.width - x), height = min(256, coefficients.height - y)
        try modularTokens(width: width, height: height, value: { i in
            try source.sample(channel: source.layouts.count - 1, x: x + i % width, y: y + i / width)
        }, emit: emit)
    }
    private func dcTokens(group: Int, _ emit: (UInt32) throws -> Void) throws {
        let region = dcRegion(group)
        for c in [1,0,2] {
            try modularTokens(width: region.width, height: region.height,
                value: { coefficients.dc[c][(region.y + $0 / region.width) * coefficients.blocksX + region.x + $0 % region.width] }, emit: emit)
        }
    }
    private func metadataTokens(group: Int, indices: [Int], _ emit: (UInt32) throws -> Void) throws {
        let region = dcRegion(group), count = indices.count
        let tw = (region.width + 7) / 8, th = (region.height + 7) / 8
        for _ in 0..<2 { try modularTokens(width: tw, height: th, value: { _ in 0 }, emit: emit) }
        try modularTokens(width: count, height: 2,
            value: { $0 < count ? coefficients.strategies[indices[$0]] : coefficients.quantAC[indices[$0 - count]] - 1 }, emit: emit)
        try modularTokens(width: region.width, height: region.height,
            value: { _ in 0 }, emit: emit)
    }
    private func acTokens(group: Int, _ emit: (UInt32) throws -> Void) throws {
        let x0 = group % groupsX * 32, y0 = group / groupsX * 32
        let width = min(32, coefficients.blocksX - x0), height = min(32, coefficients.blocksY - y0)
        if let transforms = coefficients.transforms {
            var orders: [Int: [Int]] = [:]
            for transform in transforms where transform.x >= x0 && transform.x < x0 + width && transform.y >= y0 && transform.y < y0 + height {
                try budget.checkpoint()
                let covered = transform.coveredCells, count = covered * 64, offset = transform.coefficientOffset
                let order: [Int]
                if let cached = orders[transform.orderBucket] { order = cached }
                else {
                    order = try VarDCTOrders.natural(width: max(transform.cellsX,transform.cellsY),
                        height: min(transform.cellsX,transform.cellsY), budget: budget)
                    orders[transform.orderBucket] = order
                }
                for c in [1,0,2] {
                    var nonzeros = 0
                    for k in covered..<count where coefficients.ac[c][offset + order[k]] != 0 { nonzeros += 1 }
                    try emit(UInt32(nonzeros))
                    for k in covered..<count {
                        if nonzeros == 0 { break }
                        let value = coefficients.ac[c][offset + order[k]]
                        try emit(ZigZag.pack(value)); if value != 0 { nonzeros -= 1 }
                    }
                }
            }
            return
        }
        for y in 0..<height { for x in 0..<width {
            try budget.checkpoint()
            let offset = ((y0 + y) * coefficients.blocksX + x0 + x) * 64
            for c in [1,0,2] {
                var nonzeros = 0
                for k in 1..<64 where coefficients.ac[c][offset + Self.order[k]] != 0 { nonzeros += 1 }
                try emit(UInt32(nonzeros))
                for k in 1..<64 {
                    if nonzeros == 0 { break }
                    let value = coefficients.ac[c][offset + Self.order[k]]
                    try emit(ZigZag.pack(value)); if value != 0 { nonzeros -= 1 }
                }
            }
        } }
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
    private func lfGlobal(_ modular: VarDCTPrefix, to writer: inout BitWriter) throws {
        writer.writeBit(true) // default DC quantisation
        try writer.writeU32(coefficients.globalScale, distributions: (.offset(constant: 1, extraBits: 11),
            .offset(constant: 2049, extraBits: 11), .offset(constant: 4097, extraBits: 12), .offset(constant: 8193, extraBits: 16)))
        try writer.writeU32(coefficients.quantDC, distributions: (.literal(16), .offset(constant: 1, extraBits: 5),
            .offset(constant: 1, extraBits: 8), .offset(constant: 1, extraBits: 16)))
        writer.writeBit(true); writer.writeBit(true); writer.writeBit(true) // default contexts/CfL, global tree
        try tree(to: &writer); try modular.writeHeader(to: &writer, contexts: 1)
        if coefficients.hasAlpha {
            try GroupHeader.default.write(to: &writer)
            if groupsX * groupsY == 1 {
                try alphaTokens(group: 0) { try modular.write($0, to: &writer) }
            }
        }
    }
    private func dcGroup(_ group: Int, _ modular: VarDCTPrefix, to writer: inout BitWriter) throws {
        let region = dcRegion(group), indices = try transformIndices(group)
        guard !indices.isEmpty else { throw VarDCTError.invalidTransform }
        writer.write(bits: 2, value: 0)
        try GroupHeader.default.write(to: &writer)
        try dcTokens(group: group) { try modular.write($0, to: &writer) }
        let bits = Int(ceilLog2(UInt32(region.width * region.height)))
        if bits > 0 { writer.write(bits: bits, value: UInt32(indices.count - 1)) }
        try GroupHeader.default.write(to: &writer)
        try metadataTokens(group: group, indices: indices) { try modular.write($0, to: &writer) }
    }
    private func hfGlobal(_ ac: VarDCTPrefix, to writer: inout BitWriter) throws {
        writer.writeBit(true) // default AC matrices
        let bits = Int(ceilLog2(UInt32(groupsX * groupsY)))
        if bits > 0 { writer.write(bits: bits, value: 0) } // one histogram
        try writer.writeU32(0, distributions: (.literal(0x5f), .literal(0x13), .literal(0), .bits(13)))
        try ac.writeHeader(to: &writer, contexts: 15 * 495)
    }
    private func imageHeader(to writer: inout BitWriter) throws {
        writer.write(bits: 8, value: 0xff); writer.write(bits: 8, value: 0x0a)
        try SizeHeader(xsize: UInt32(coefficients.width), ysize: UInt32(coefficients.height)).write(to: &writer)
        let bits = BitDepth(floatingPoint: false, bitsPerSample: UInt32(coefficients.bits))
        let extras: [ExtraChannelInfo] = coefficients.hasAlpha ? [.init(type: .alpha, bitDepth: bits, dimShift: 0, name: "")] : []
        let metadata = ImageMetadata(allDefault: false, orientation: 1, intrinsicSize: nil, preview: nil, animation: nil,
            bitDepth: bits, modular16BitBufferSufficient: true, extraChannels: extras, xybEncoded: true,
            colorEncoding: coefficients.grayscale ? .grayscaleD65 : .srgb,
            intensityTarget: 255, minNits: 0, relativeToMaxDisplay: false, linearBelow: 0)
        try metadata.write(to: &writer); writer.writeBit(true); writer.alignToByte()
    }
    private func frameHeader(to writer: inout BitWriter) throws {
        let frame = FrameHeader(allDefault: false, frameType: .regular, encoding: .varDCT, flags: coefficients.dcSmoothing ? 0 : 128,
            colorTransform: .xyb, chromaSubsampling: .default, upsampling: 1, extraChannelUpsampling: [],
            groupSizeShift: 1, xQmScale: 2, bQmScale: 2, passes: .default, dcLevel: 0,
            customSizeOrOrigin: false, frameOrigin: (0,0), frameSize: nil, blendingInfo: .default,
            extraChannelBlendingInfo: [], animationFrame: .default, isLast: true, saveAsReference: 0,
            saveBeforeColorTransform: false, name: "", loopFilter: .init(allDefault: false, gab: coefficients.gaborish, epfIters: 0))
        try frame.write(to: &writer, context: .init(xybEncoded: true, numExtraChannels: coefficients.hasAlpha ? 1 : 0))
    }
}
