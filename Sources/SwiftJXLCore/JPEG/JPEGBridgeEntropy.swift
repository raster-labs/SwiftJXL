// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Entropy coding utilities for the reversible JPEG-to-VarDCT coefficient bridge (ISO/IEC 18181-1 §§7, 8, 9.3).
package enum JPEGBridgeEntropy {
    /// Builds a `PrefixCodeTable` from symbol frequencies with canonical code lengths bounded to 15 bits.
    package static func buildPrefixTable(
        frequencies: [Int],
        alphabetSize: Int
    ) throws -> PrefixCodeTable {
        guard alphabetSize > 1 else {
            return try PrefixCodeTable(lengths: [0])
        }
        let lengths = buildBoundedCodeLengths(frequencies: frequencies, alphabetSize: alphabetSize, maxBits: 15)
        return try PrefixCodeTable(lengths: lengths.map { UInt8($0) })
    }

    /// Encodes a single-cluster prefix-coded entropy section and its token stream.
    package static func writeSingleClusterStream(
        values: [UInt32],
        numContexts: Int,
        config: HybridUintConfig,
        to writer: inout BitWriter,
        policy: JPEGBridgePolicy
    ) throws {
        try policy.checkpoint()
        var maxToken = 0
        var counts: [Int] = [0]
        for (idx, val) in values.enumerated() {
            if (idx & 1023) == 0 { try policy.checkpoint() }
            let encoded = config.encode(val)
            let tok = Int(encoded.token)
            if tok >= counts.count {
                counts.append(contentsOf: repeatElement(0, count: tok - counts.count + 1))
            }
            counts[tok] += 1
            if tok > maxToken { maxToken = tok }
        }
        if values.isEmpty {
            counts[0] = 1
        }
        let alphabetSize = maxToken + 1
        let table = try buildPrefixTable(frequencies: counts, alphabetSize: alphabetSize)
        let header = EntropySectionHeader(
            lz77: .disabled,
            contextMap: .trivial(numContexts: max(1, numContexts)),
            usePrefixCode: true,
            logAlphaSize: 15,
            uintConfigs: [config]
        )
        let codebook = MultiClusterCodebook(
            huffmanTables: [table],
            ansCounts: [],
            alphabetSizes: [alphabetSize]
        )
        try header.write(to: &writer, numContexts: max(1, numContexts))
        try codebook.write(to: &writer, header: header)
        let tokenWriter = TokenStreamWriter(header: header, codebook: codebook)
        for (idx, val) in values.enumerated() {
            if (idx & 1023) == 0 { try policy.checkpoint() }
            try tokenWriter.writeToken(context: 0, value: val, to: &writer)
        }
    }

    /// Writes a self-contained 1-leaf Modular tree (`predictor`, `offset = 0`, `multiplier = 1`) and single-cluster codebook.
    package static func writeFlatModularSubstream(
        channels: [[Int32]],
        dimensions: [(width: Int, height: Int)],
        predictor: UInt32 = 0,
        config: HybridUintConfig = HybridUintConfig(splitExponent: 4, msbInToken: 1, lsbInToken: 0),
        to writer: inout BitWriter,
        policy: JPEGBridgePolicy
    ) throws {
        try policy.checkpoint()
        guard channels.count == dimensions.count else {
            throw JPEGEntropyError.malformed
        }

        // 1. GroupHeader: use_global_tree = false, wp_header.all_default = true, num_transforms = 0
        writer.writeBit(false)
        writer.writeBit(true)
        writer.write(bits: 2, value: 0)

        // 2. 1-leaf Modular MA tree (ISO/IEC 18181-1 §8.1.3):
        //    5 tokens for a single leaf node:
        //    - kPropertyContext (1) = 0 (leaf marker, property = -1)
        //    - kPredictorContext (2) = predictor
        //    - kOffsetContext (3) = 0
        //    - kMultiplierLogContext (4) = 0
        //    - kMultiplierBitsContext (5) = 0
        let treeConfig = HybridUintConfig(splitExponent: 4, msbInToken: 0, lsbInToken: 0)
        let treeTokens: [(ctx: Int, val: UInt32)] = [
            (1, 0),
            (2, predictor),
            (3, 0),
            (4, 0),
            (5, 0)
        ]
        var treeFreqs = [Int](repeating: 0, count: Int(predictor) + 1)
        for t in treeTokens {
            treeFreqs[Int(t.val)] += 1
        }
        let treeAlpha = Int(predictor) + 1
        let treeTable = try buildPrefixTable(frequencies: treeFreqs, alphabetSize: treeAlpha)
        let treeHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: .trivial(numContexts: 6),
            usePrefixCode: true,
            logAlphaSize: 15,
            uintConfigs: [treeConfig]
        )
        let treeCodebook = MultiClusterCodebook(
            huffmanTables: [treeTable],
            ansCounts: [],
            alphabetSizes: [treeAlpha]
        )
        try treeHeader.write(to: &writer, numContexts: 6)
        try treeCodebook.write(to: &writer, header: treeHeader)
        let treeStreamWriter = TokenStreamWriter(header: treeHeader, codebook: treeCodebook)
        for t in treeTokens {
            try treeStreamWriter.writeToken(context: t.ctx, value: t.val, to: &writer)
        }

        // 3. Collect residual tokens for all channels
        var packedResiduals: [UInt32] = []
        let totalSamples = dimensions.reduce(0) { $0 + $1.width * $1.height }
        packedResiduals.reserveCapacity(totalSamples)

        for (cIdx, plane) in channels.enumerated() {
            let (w, h) = dimensions[cIdx]
            guard plane.count == w * h else {
                throw JPEGEntropyError.malformed
            }
            for y in 0..<h {
                if (y & 63) == 0 { try policy.checkpoint() }
                let rowBase = y * w
                for x in 0..<w {
                    let sample = plane[rowBase + x]
                    let pred: Int32
                    switch predictor {
                    case 1: // West (Left)
                        pred = x > 0 ? plane[rowBase + x - 1] : (y > 0 ? plane[(y - 1) * w] : 0)
                    case 2: // North (Top)
                        pred = y > 0 ? plane[(y - 1) * w + x] : (x > 0 ? plane[rowBase + x - 1] : 0)
                    case 5: // Gradient (Clamped West + North - NorthWest)
                        if x == 0 && y == 0 {
                            pred = 0
                        } else if y == 0 {
                            pred = plane[rowBase + x - 1]
                        } else if x == 0 {
                            pred = plane[(y - 1) * w]
                        } else {
                            let wVal = Int64(plane[rowBase + x - 1])
                            let nVal = Int64(plane[(y - 1) * w + x])
                            let nwVal = Int64(plane[(y - 1) * w + x - 1])
                            let lo = min(wVal, nVal)
                            let hi = max(wVal, nVal)
                            pred = Int32(clamping: min(hi, max(lo, wVal + nVal - nwVal)))
                        }
                    default: // Zero
                        pred = 0
                    }
                    let residual = sample &- pred
                    packedResiduals.append(ZigZag.pack(residual))
                }
            }
        }

        // 4. Write single-cluster Modular token stream
        try writeSingleClusterStream(
            values: packedResiduals,
            numContexts: 1,
            config: config,
            to: &writer,
            policy: policy
        )
    }

    /// Clusters VarDCT HF contexts by token statistics and writes the `HfGlobal` codebook and `HfPass` group streams.
    package static func writeClusteredACStreams(
        groupTokens: [[(context: Int, value: UInt32)]],
        numContexts: Int,
        to hfGlobalWriter: inout BitWriter,
        policy: JPEGBridgePolicy
    ) throws -> [BitWriter] {
        try policy.checkpoint()
        let nzLimit = VarDCTEntropy.defaultNumBlockClusters * VarDCTEntropy.nonZeroBuckets

        // Partition active contexts into up to 12 semantic/statistical clusters:
        // - Cluster 0: unused contexts + NZ contexts with low mean
        // - Cluster 1: NZ contexts with medium/high mean
        // - Clusters 2..11: AC zero-density contexts bucketed by zero-probability P(val == 0)
        var ctxTotal = [Int](repeating: 0, count: numContexts)
        var ctxZeros = [Int](repeating: 0, count: numContexts)
        var ctxSum = [UInt64](repeating: 0, count: numContexts)

        for group in groupTokens {
            try policy.checkpoint()
            for tok in group {
                let c = tok.context
                ctxTotal[c] &+= 1
                if tok.value == 0 {
                    ctxZeros[c] &+= 1
                } else {
                    ctxSum[c] &+= UInt64(tok.value)
                }
            }
        }

        // Thresholds for P(val == 0) in parts per 1024 for AC coefficient contexts
        let zeroRatioThresholds = [256, 448, 576, 680, 760, 824, 880, 928, 964]
        var rawClusterForCtx = [Int](repeating: 0, count: numContexts)
        var clusterUsed = [Bool](repeating: false, count: 2 + zeroRatioThresholds.count + 1)
        clusterUsed[0] = true

        for ctx in 0..<numContexts {
            let total = ctxTotal[ctx]
            guard total > 0 else {
                rawClusterForCtx[ctx] = 0
                continue
            }
            if ctx < nzLimit {
                let meanX16 = (ctxSum[ctx] << 4) / UInt64(total)
                let cl = meanX16 >= 64 ? 1 : 0
                rawClusterForCtx[ctx] = cl
                clusterUsed[cl] = true
            } else {
                let zeroPermille = (ctxZeros[ctx] << 10) / total
                var bucket = 0
                for t in zeroRatioThresholds where zeroPermille >= t {
                    bucket += 1
                }
                let cl = 2 + bucket
                rawClusterForCtx[ctx] = cl
                clusterUsed[cl] = true
            }
        }

        // Compact active clusters to contiguous IDs 0..<numClusters
        var compactID = [Int](repeating: 0, count: clusterUsed.count)
        var numClusters = 0
        for i in 0..<clusterUsed.count where clusterUsed[i] {
            compactID[i] = numClusters
            numClusters += 1
        }
        numClusters = max(1, numClusters)

        var cmapBytes = [UInt8](repeating: 0, count: numContexts)
        for ctx in 0..<numContexts {
            cmapBytes[ctx] = UInt8(compactID[rawClusterForCtx[ctx]])
        }

        var uintConfigs = [HybridUintConfig](repeating: HybridUintConfig(splitExponent: 4, msbInToken: 1, lsbInToken: 0), count: numClusters)
        for rawCl in 0..<2 where clusterUsed[rawCl] {
            uintConfigs[compactID[rawCl]] = HybridUintConfig(splitExponent: 3, msbInToken: 1, lsbInToken: 0)
        }

        var clusterFreqs = [[Int]](repeating: [0], count: numClusters)
        var clusterMaxTok = [Int](repeating: 0, count: numClusters)

        for group in groupTokens {
            try policy.checkpoint()
            for tok in group {
                let cl = Int(cmapBytes[tok.context])
                let cfg = uintConfigs[cl]
                let exp = cfg.encode(tok.value)
                let sym = Int(exp.token)
                if sym >= clusterFreqs[cl].count {
                    clusterFreqs[cl].append(contentsOf: repeatElement(0, count: sym - clusterFreqs[cl].count + 1))
                }
                clusterFreqs[cl][sym] &+= 1
                if sym > clusterMaxTok[cl] {
                    clusterMaxTok[cl] = sym
                }
            }
        }

        var tables: [PrefixCodeTable] = []
        var alphaSizes: [Int] = []
        tables.reserveCapacity(numClusters)
        alphaSizes.reserveCapacity(numClusters)

        for cl in 0..<numClusters {
            if clusterFreqs[cl].allSatisfy({ $0 == 0 }) {
                clusterFreqs[cl][0] = 1
            }
            let alpha = clusterMaxTok[cl] + 1
            alphaSizes.append(alpha)
            tables.append(try buildPrefixTable(frequencies: clusterFreqs[cl], alphabetSize: alpha))
        }

        let contextMap = try ContextMap(numClusters: numClusters, map: cmapBytes)
        let header = EntropySectionHeader(
            lz77: .disabled,
            contextMap: contextMap,
            usePrefixCode: true,
            logAlphaSize: 15,
            uintConfigs: uintConfigs
        )
        let codebook = MultiClusterCodebook(
            huffmanTables: tables,
            ansCounts: [],
            alphabetSizes: alphaSizes
        )

        try header.write(to: &hfGlobalWriter, numContexts: numContexts)
        try codebook.write(to: &hfGlobalWriter, header: header)

        let tokenWriter = TokenStreamWriter(header: header, codebook: codebook)
        if groupTokens.count == 1 {
            for (idx, tok) in groupTokens[0].enumerated() {
                if (idx & 1023) == 0 { try policy.checkpoint() }
                try tokenWriter.writeToken(context: tok.context, value: tok.value, to: &hfGlobalWriter)
            }
            return []
        }

        var groupWriters: [BitWriter] = []
        groupWriters.reserveCapacity(groupTokens.count)

        for group in groupTokens {
            try policy.checkpoint()
            var gw = BitWriter()
            for (idx, tok) in group.enumerated() {
                if (idx & 1023) == 0 { try policy.checkpoint() }
                try tokenWriter.writeToken(context: tok.context, value: tok.value, to: &gw)
            }
            groupWriters.append(gw)
        }

        return groupWriters
    }

    // MARK: - Depth-Limited Canonical Code Length Builder

    private static func buildBoundedCodeLengths(
        frequencies: [Int],
        alphabetSize: Int,
        maxBits: Int
    ) -> [Int] {
        var active: [(sym: Int, freq: Int)] = []
        for s in 0..<alphabetSize {
            let f = s < frequencies.count ? frequencies[s] : 0
            if f > 0 {
                active.append((s, f))
            }
        }
        var lengths = [Int](repeating: 0, count: alphabetSize)
        if active.isEmpty {
            lengths[0] = 0
            return lengths
        }
        if active.count == 1 {
            if alphabetSize == 1 {
                lengths[0] = 0
                return lengths
            }
            let s = active[0].sym
            let pad = (s == 0) ? 1 : 0
            lengths[s] = 1
            lengths[pad] = 1
            return lengths
        }
        if active.count == 2 {
            lengths[active[0].sym] = 1
            lengths[active[1].sym] = 1
            return lengths
        }

        // Standard Huffman tree construction followed by Kraft-sum enforcement at `maxBits`
        struct Node {
            var weight: Int
            var left: Int
            var right: Int
            var symbol: Int
        }

        var nodes: [Node] = active.map { Node(weight: $0.freq, left: -1, right: -1, symbol: $0.sym) }
        var available = Array(0..<nodes.count)

        while available.count > 1 {
            available.sort { a, b in
                if nodes[a].weight != nodes[b].weight {
                    return nodes[a].weight > nodes[b].weight
                }
                return a > b
            }
            let n1 = available.removeLast()
            let n2 = available.removeLast()
            let parentIdx = nodes.count
            nodes.append(Node(weight: nodes[n1].weight + nodes[n2].weight, left: n1, right: n2, symbol: -1))
            available.append(parentIdx)
        }

        var symbolDepths: [(sym: Int, freq: Int, len: Int)] = []
        symbolDepths.reserveCapacity(active.count)

        func traverse(_ idx: Int, depth: Int) {
            let node = nodes[idx]
            if node.symbol >= 0 {
                symbolDepths.append((node.symbol, node.weight, min(maxBits, max(1, depth))))
            } else {
                traverse(node.left, depth: depth + 1)
                traverse(node.right, depth: depth + 1)
            }
        }
        traverse(available[0], depth: 0)

        // Sort by frequency ascending (then symbol descending) to adjust Kraft sum to 1 << maxBits
        symbolDepths.sort { a, b in
            if a.freq != b.freq { return a.freq < b.freq }
            return a.sym > b.sym
        }

        let targetKraft = 1 << maxBits
        var kraftSum = symbolDepths.reduce(0) { $0 + (1 << (maxBits - $1.len)) }

        while kraftSum > targetKraft {
            for i in 0..<symbolDepths.count where symbolDepths[i].len < maxBits {
                let oldContrib = 1 << (maxBits - symbolDepths[i].len)
                symbolDepths[i].len += 1
                let newContrib = 1 << (maxBits - symbolDepths[i].len)
                kraftSum -= (oldContrib - newContrib)
                if kraftSum <= targetKraft { break }
            }
        }

        while kraftSum < targetKraft {
            let deficit = targetKraft - kraftSum
            for i in (0..<symbolDepths.count).reversed() where symbolDepths[i].len > 1 {
                let delta = 1 << (maxBits - symbolDepths[i].len)
                if delta <= deficit {
                    symbolDepths[i].len -= 1
                    kraftSum += delta
                    break
                }
            }
        }

        for item in symbolDepths {
            lengths[item.sym] = item.len
        }
        return lengths
    }
}
