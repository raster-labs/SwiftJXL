// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift 57e81cb9e2411d1efac435b429a306a031744c1e, Sources/JXLSwift/Entropy/ANSTokenStreamWriter.swift.
// ANSTokenStreamWriter — the encoder counterpart to the ANS path of
// `TokenStreamReader` (+ `ANSStreamDecoder`). Produces the exact
// interleaved LSB-first bitstream the streaming rANS decoder consumes.
//
// ISO/IEC 18181-1 §C.6.3 / libjxl `enc_ans.cc`. A JXL ANS token
// section is a SINGLE bitstream that interleaves three things, all
// read forward by the decoder:
//
//   init(32) , [renorm_0(16)?] , extra_0 , [renorm_1(16)?] , extra_1 , …
//
// where `renorm_i` is the 16-bit refill the decoder reads after
// decoding symbol i (only when its rANS state drops below 2^16), and
// `extra_i` are the HybridUint extra bits for token i. rANS encodes in
// REVERSE, so the refill words are produced last-symbol-first; reversed,
// they line up with the decoder's forward reads. The extra bits are
// plain forward bits, emitted in token order right after each token's
// refill — matching the reader's `readANSSymbol` → `expand` sequence.
//
// **Alias layout = libjxl-compatible.** The encode step is the exact
// inverse of `ANSStreamDecoder.readSymbol`'s decode step, including the
// `AliasTable` slot assignment. Because our `AliasTable` is a faithful
// port of libjxl `InitAliasTable` (verified byte-exact against
// cjxl-emitted streams), a stream this writer produces is decodable by
// libjxl/djxl, not just by our own reader. The encoder inverts the
// alias lookup by scanning all `tabSize` slots once per cluster to build
// a `(symbol, residue) → slot` map.
//
// Scope: `lz77.enabled == false` (the bridge + most sections). The
// frequency tables MUST be the on-wire (quantised) distributions the
// decoder reconstructs — see `SpecANSDistribution.writeComplex` — or the
// encode and decode alias tables disagree.

import Foundation

package enum ANSTokenStreamWriterError: Error, Sendable {
    case notANSSection
    case lz77NotSupported
    case contextOutOfRange(Int, max: Int)
    case clusterOutOfRange(Int, max: Int)
    case symbolHasZeroFrequency(cluster: Int, symbol: Int)
    case alias(AliasTableError)
    case invalidReplay
}

/// Exact UInt32 division for a validated positive ANS frequency. The ceiling
/// reciprocal can overestimate the quotient by at most one; the product check
/// corrects it. Zero-frequency entries are retained as zero and rejected by the
/// writer before this operation. This changes no entropy or rounding semantics.
package enum ANSReciprocalDivision {
    @inline(__always) package static func reciprocal(_ frequency: UInt32) -> UInt64 {
        frequency == 0 ? 0 : ((UInt64(1) << 32) + UInt64(frequency) - 1) / UInt64(frequency)
    }
    @inline(__always) package static func divide(_ value: UInt32, frequency: UInt32,
                                                reciprocal: UInt64) -> (quotient: UInt32, remainder: UInt32) {
        // For frequency >= 1 the first product is at most (2^32-1)*2^32,
        // and the estimated quotient times frequency is at most value+frequency.
        let estimate = (UInt64(value) &* reciprocal) >> 32
        let product = estimate &* UInt64(frequency)
        let quotient = UInt32(estimate) &- (product > UInt64(value) ? 1 : 0)
        return (quotient, value &- quotient &* frequency)
    }
}

/// Buffers context-routed integer tokens and emits them as one
/// interleaved rANS bitstream (init + refill words + HybridUint extra
/// bits) matching `TokenStreamReader`'s ANS path.
package struct ANSTokenStreamWriter: Sendable {
    package let header: EntropySectionHeader
    package let codebook: MultiClusterCodebook

    private struct SymbolInfo: Sendable {
        let freq: UInt32
        let residueStart: UInt32
        let reciprocal: UInt64
    }

    /// Per-cluster encode state derived from the on-wire frequencies.
    private struct ClusterEnc: Sendable {
        let symbols: [SymbolInfo]         // per symbol (freq, residueStart, reciprocal)
        let slotForResidue: [UInt32]      // contiguous 4096-slot inverse table
    }
    private let clusters: [ClusterEnc]

    private struct PendingToken: Sendable {
        let cluster: Int
        let symbol: UInt32
        let extraBits: UInt32
        let extraNBits: Int
    }

    /// Buffered tokens in forward order: the cluster + the HybridUint
    /// expansion (token symbol + raw extra bits).
    private var pending: [PendingToken] = []

    package init(
        header: EntropySectionHeader,
        codebook: MultiClusterCodebook
    ) throws {
        guard !header.usePrefixCode else {
            throw ANSTokenStreamWriterError.notANSSection
        }
        guard !header.lz77.enabled else {
            throw ANSTokenStreamWriterError.lz77NotSupported
        }
        self.header = header
        self.codebook = codebook
        let logAlpha = header.logAlphaSize
        let range = Int(ANSConstants.tabSize)
        var built: [ClusterEnc] = []
        built.reserveCapacity(codebook.ansCounts.count)
        for counts in codebook.ansCounts {
            // Invert the alias lookup: scan every slot once, recording
            // the slot for each (symbol, residue=offset) pair.
            let alias: AliasTable
            do {
                alias = try AliasTable(
                    distribution: counts,
                    logRange: ANSConstants.logTabSize,
                    logAlphaSize: logAlpha)
            } catch let e as AliasTableError {
                throw ANSTokenStreamWriterError.alias(e)
            }
            var symInfos: [SymbolInfo] = []
            symInfos.reserveCapacity(counts.count)
            var total = 0
            for c in counts {
                let f = UInt32(bitPattern: c)
                symInfos.append(SymbolInfo(
                    freq: f,
                    residueStart: UInt32(truncatingIfNeeded: total),
                    reciprocal: ANSReciprocalDivision.reciprocal(f)
                ))
                total += Int(f)
            }
            var slotForResidue = [UInt32](repeating: 0, count: total)
            for slot in 0..<range {
                let lr = alias.lookup(slot: UInt32(slot))
                let sym = lr.value, off = Int(lr.offset)
                if sym >= 0 && sym < symInfos.count && off < Int(symInfos[sym].freq) {
                    slotForResidue[Int(symInfos[sym].residueStart) + off] = UInt32(slot)
                }
            }
            built.append(ClusterEnc(symbols: symInfos, slotForResidue: slotForResidue))
        }
        self.clusters = built
    }

    /// Pre-reserve buffer capacity for `count` tokens (callers usually
    /// know the pixel/token count up front; avoids growth reallocations).
    package mutating func reserveCapacity(_ count: Int) {
        pending.reserveCapacity(count)
    }

    /// Buffer one token at context `ctx`. Order matters — tokens are
    /// emitted (and the decoder reads them) in this call order.
    package mutating func writeToken(
        context ctx: Int, value: UInt32
    ) throws {
        // Bound cancellation/deadline latency to 256 tokens, including
        // zero-bit symbols. Avoid clock/task-local/lock work per sample.
        if pending.count & 255 == 0 { try ScalarEncodingWork.checkpoint() }
        guard ctx >= 0 && ctx < header.contextMap.numContexts else {
            throw ANSTokenStreamWriterError.contextOutOfRange(
                ctx, max: header.contextMap.numContexts - 1)
        }
        let cluster = Int(header.contextMap.map[ctx])
        guard cluster < header.numHistograms else {
            throw ANSTokenStreamWriterError.clusterOutOfRange(
                cluster, max: header.numHistograms - 1)
        }
        let exp = header.uintConfigs[cluster].encode(value)
        pending.append(PendingToken(cluster: cluster, symbol: exp.token, extraBits: exp.extraBits, extraNBits: exp.extraNBits))
    }

    /// Emit the buffered tokens as the interleaved rANS bitstream into
    /// `w` (continuing the same bit position — the decoder reads the
    /// 32-bit state init immediately after the per-cluster codebook).
    package mutating func finish(to w: inout BitWriter) throws {
        try ScalarEncodingWork.checkpoint()
        let logTab = UInt32(ANSConstants.logTabSize)
        let renormShift = UInt32(32 - ANSConstants.logTabSize)
        let noRefill: UInt32 = .max
        var refills = [UInt32](repeating: noRefill, count: pending.count)
        var state: UInt32 = ANSConstants.initialState
        var i = pending.count - 1
        while i >= 0 {
            if i & 255 == 0 { try ScalarEncodingWork.checkpoint() }
            let t = pending[i]
            let enc = clusters[t.cluster]
            let sym = Int(t.symbol)
            guard sym < enc.symbols.count else {
                throw ANSTokenStreamWriterError.symbolHasZeroFrequency(
                    cluster: t.cluster, symbol: sym)
            }
            let info = enc.symbols[sym]
            let f = info.freq
            guard f > 0 else {
                throw ANSTokenStreamWriterError.symbolHasZeroFrequency(
                    cluster: t.cluster, symbol: sym)
            }
            if (state >> renormShift) >= f {
                refills[i] = state & 0xFFFF
                state >>= 16
            }
            let division = ANSReciprocalDivision.divide(state, frequency: f, reciprocal: info.reciprocal)
            let slot = enc.slotForResidue[Int(info.residueStart &+ division.remainder)]
            state = (division.quotient &<< logTab) &+ slot
            i -= 1
        }
        w.write(bits: 32, value: state)
        for (j, t) in pending.enumerated() {
            if j & 255 == 0 { try ScalarEncodingWork.checkpoint() }
            let refill = refills[j]
            if refill != noRefill { w.write(bits: 16, value: refill) }
            if t.extraNBits > 0 {
                w.write(bits: t.extraNBits, value: t.extraBits)
            }
        }
    }

    /// Compact single-cluster stream for a caller-admitted group. Reuses
    /// its UInt16 symbol buffer for refill words, plus one flag bit per symbol.
    /// The synchronous replay must supply the same values in forward order.
    package func finishSingleCluster(symbols: inout [UInt16],
        replay: (_ emit: (UInt32) throws -> Void) throws -> Void,
        to w: inout BitWriter) throws {
        let currentWork = ScalarEncodingWork.current
        @inline(__always)
        func checkWork() throws {
            if let currentWork {
                try currentWork.checkpoint()
            } else {
                try Task.checkCancellation()
            }
        }
        try checkWork()
        guard clusters.count == 1 else {
            throw ANSTokenStreamWriterError.clusterOutOfRange(clusters.count, max: 1)
        }
        let enc = clusters[0], config = header.uintConfigs[0]
        let splitThreshold = UInt32(1) << config.splitExponent
        let simpleConfig = config.msbInToken == 0 && config.lsbInToken == 0
        let logTab = UInt32(ANSConstants.logTabSize)
        let renormShift = UInt32(32 - ANSConstants.logTabSize)
        var hasRefill = [UInt8](repeating: 0, count: (symbols.count + 7) >> 3)
        var state = ANSConstants.initialState
        try enc.symbols.withUnsafeBufferPointer { symInfos in
            try enc.slotForResidue.withUnsafeBufferPointer { slots in
                try symbols.withUnsafeMutableBufferPointer { mutableSymbols in
                    try hasRefill.withUnsafeMutableBufferPointer { flags in
                        let infoBase = symInfos.baseAddress!
                        let infoCount = symInfos.count
                        let slotsBase = slots.baseAddress!
                        var i = mutableSymbols.count - 1
                        while i >= 0 {
                            if i & 255 == 0 { try checkWork() }
                            let symbol = Int(mutableSymbols[i])
                            guard symbol < infoCount else {
                                throw ANSTokenStreamWriterError.symbolHasZeroFrequency(cluster: 0, symbol: symbol)
                            }
                            let info = infoBase[symbol]
                            let f = info.freq
                            guard f > 0 else {
                                throw ANSTokenStreamWriterError.symbolHasZeroFrequency(cluster: 0, symbol: symbol)
                            }
                            if (state >> renormShift) >= f {
                                mutableSymbols[i] = UInt16(truncatingIfNeeded: state)
                                flags[i >> 3] |= UInt8(1 << (i & 7))
                                state >>= 16
                            }
                            let division = ANSReciprocalDivision.divide(state,
                                frequency: f, reciprocal: info.reciprocal)
                            state = (division.quotient &<< logTab)
                                &+ slotsBase[Int(info.residueStart &+ division.remainder)]
                            i -= 1
                        }
                    }
                }
            }
        }
        w.write(bits: 32, value: state)
        var index = 0
        let totalCount = symbols.count
        try symbols.withUnsafeBufferPointer { symBuf in
            try hasRefill.withUnsafeBufferPointer { flagBuf in
                try replay { value in
                    guard index < totalCount else { throw ANSTokenStreamWriterError.invalidReplay }
                    if index & 255 == 0 { try checkWork() }
                    if flagBuf[index >> 3] & UInt8(1 << (index & 7)) != 0 {
                        w.write(bits: 16, value: UInt32(symBuf[index]))
                    }
                    if value >= splitThreshold {
                        if simpleConfig {
                            let n = 31 &- value.leadingZeroBitCount
                            if n > 0 {
                                w.write(bits: n, value: value &- (UInt32(1) &<< UInt32(n)))
                            }
                        } else {
                            let token = config.encode(value)
                            if token.extraNBits > 0 { w.write(bits: token.extraNBits, value: token.extraBits) }
                        }
                    }
                    index += 1
                }
            }
        }
        guard index == totalCount else { throw ANSTokenStreamWriterError.invalidReplay }
        try checkWork()
    }

    /// Direct chunked single-cluster emission without per-token closure dispatch.
    package func finishSingleCluster(
        symbols: inout [UInt16],
        valueChunks: [[UInt32]],
        to w: inout BitWriter
    ) throws {
        let currentWork = ScalarEncodingWork.current
        @inline(__always)
        func checkWork() throws {
            if let currentWork {
                try currentWork.checkpoint()
            } else {
                try Task.checkCancellation()
            }
        }
        try checkWork()
        guard clusters.count == 1 else {
            throw ANSTokenStreamWriterError.clusterOutOfRange(clusters.count, max: 1)
        }
        let enc = clusters[0], config = header.uintConfigs[0]
        let splitThreshold = UInt32(1) << config.splitExponent
        let simpleConfig = config.msbInToken == 0 && config.lsbInToken == 0
        let logTab = UInt32(ANSConstants.logTabSize)
        let renormShift = UInt32(32 - ANSConstants.logTabSize)
        let totalCount = symbols.count
        var hasRefill = [UInt8](repeating: 0, count: (totalCount + 7) >> 3)
        var state = ANSConstants.initialState
        try enc.symbols.withUnsafeBufferPointer { symInfos in
            try enc.slotForResidue.withUnsafeBufferPointer { slots in
                try symbols.withUnsafeMutableBufferPointer { mutableSymbols in
                    try hasRefill.withUnsafeMutableBufferPointer { flags in
                        let infoBase = symInfos.baseAddress!
                        let infoCount = symInfos.count
                        let slotsBase = slots.baseAddress!
                        let symBase = mutableSymbols.baseAddress!
                        let flagBase = flags.baseAddress!
                        var i = totalCount - 1
                        while i >= 0 {
                            if i & 255 == 0 { try checkWork() }
                            let symbol = Int(symBase[i])
                            guard symbol < infoCount else {
                                throw ANSTokenStreamWriterError.symbolHasZeroFrequency(cluster: 0, symbol: symbol)
                            }
                            let info = infoBase[symbol]
                            let f = info.freq
                            guard f > 0 else {
                                throw ANSTokenStreamWriterError.symbolHasZeroFrequency(cluster: 0, symbol: symbol)
                            }
                            if (state >> renormShift) >= f {
                                symBase[i] = UInt16(truncatingIfNeeded: state)
                                flagBase[i >> 3] |= UInt8(1 << (i & 7))
                                state >>= 16
                            }
                            let division = ANSReciprocalDivision.divide(state,
                                frequency: f, reciprocal: info.reciprocal)
                            state = (division.quotient &<< logTab)
                                &+ slotsBase[Int(info.residueStart &+ division.remainder)]
                            i -= 1
                        }
                    }
                }
            }
        }
        w.write(bits: 32, value: state)
        var index = 0
        try symbols.withUnsafeBufferPointer { symBuf in
            try hasRefill.withUnsafeBufferPointer { flagBuf in
                let symBase = symBuf.baseAddress!
                let flagBase = flagBuf.baseAddress!
                for chunk in valueChunks {
                    try chunk.withUnsafeBufferPointer { vals in
                        let valBase = vals.baseAddress!
                        let valCount = vals.count
                        for j in 0..<valCount {
                            guard index < totalCount else { throw ANSTokenStreamWriterError.invalidReplay }
                            if index & 255 == 0 { try checkWork() }
                            if flagBase[index >> 3] & UInt8(1 << (index & 7)) != 0 {
                                w.write(bits: 16, value: UInt32(symBase[index]))
                            }
                            let value = valBase[j]
                            if value >= splitThreshold {
                                if simpleConfig {
                                    let n = 31 &- value.leadingZeroBitCount
                                    if n > 0 {
                                        w.write(bits: n, value: value &- (UInt32(1) &<< UInt32(n)))
                                    }
                                } else {
                                    let token = config.encode(value)
                                    if token.extraNBits > 0 { w.write(bits: token.extraNBits, value: token.extraBits) }
                                }
                            }
                            index &+= 1
                        }
                    }
                }
            }
        }
        guard index == totalCount else { throw ANSTokenStreamWriterError.invalidReplay }
        try checkWork()
    }

    /// Walk successive immutable chunks as ONE entropy stream, in reverse.
    /// Keeping the table buffers borrowed across the complete walk avoids
    /// per-symbol table retains and avoids a full-image flattened symbol copy.
    package func refillWordCount(singleClusterChunks chunks: [[UInt16]]) throws -> Int {
        let currentWork = ScalarEncodingWork.current
        @inline(__always)
        func checkWork() throws {
            if let currentWork {
                try currentWork.checkpoint()
            } else {
                try Task.checkCancellation()
            }
        }
        try checkWork()
        guard clusters.count == 1 else {
            throw ANSTokenStreamWriterError.clusterOutOfRange(clusters.count, max: 1)
        }
        let enc = clusters[0]
        let logTab = UInt32(ANSConstants.logTabSize)
        let renormShift = UInt32(32 - ANSConstants.logTabSize)
        return try enc.symbols.withUnsafeBufferPointer { symInfos in
            try enc.slotForResidue.withUnsafeBufferPointer { slots in
                let infoBase = symInfos.baseAddress!
                let infoCount = symInfos.count
                let slotsBase = slots.baseAddress!
                var refills = 0, processed = 0
                var state = ANSConstants.initialState
                for chunk in chunks.reversed() {
                    try chunk.withUnsafeBufferPointer { symbols in
                        let symBase = symbols.baseAddress!
                        var i = symbols.count - 1
                        while i >= 0 {
                            if processed & 255 == 0 { try checkWork() }
                            processed &+= 1
                            let symbol = Int(symBase[i])
                            guard symbol < infoCount else {
                                throw ANSTokenStreamWriterError.symbolHasZeroFrequency(cluster: 0, symbol: symbol)
                            }
                            let info = infoBase[symbol]
                            let frequency = info.freq
                            guard frequency > 0 else {
                                throw ANSTokenStreamWriterError.symbolHasZeroFrequency(cluster: 0, symbol: symbol)
                            }
                            if (state >> renormShift) >= frequency {
                                refills &+= 1
                                state >>= 16
                            }
                            let division = ANSReciprocalDivision.divide(state,
                                frequency: frequency, reciprocal: info.reciprocal)
                            state = (division.quotient &<< logTab)
                                &+ slotsBase[Int(info.residueStart &+ division.remainder)]
                            i &-= 1
                        }
                    }
                }
                return refills
            }
        }
    }

    /// Number of buffered tokens.
    package var tokenCount: Int { pending.count }

    /// The bare reverse rANS walk of `finish()` over already-expanded
    /// token symbols, counting the 16-bit refill words **without
    /// emitting anything**.
    package func refillWordCount(
        symbols: [UInt16], clusters clusterIdx: [UInt8]? = nil
    ) throws -> Int {
        if clusterIdx == nil, clusters.count == 1 {
            return try refillWordCount(singleClusterChunks: [symbols])
        }
        guard clusterIdx == nil || clusterIdx?.count == symbols.count else {
            throw ANSTokenStreamWriterError.invalidReplay
        }
        let logTab = UInt32(ANSConstants.logTabSize)
        let renormShift = UInt32(32 - ANSConstants.logTabSize)
        let tables = self.clusters
        var refills = 0
        var state: UInt32 = ANSConstants.initialState
        var i = symbols.count - 1
        while i >= 0 {
            if i & 255 == 0 { try ScalarEncodingWork.checkpoint() }
            let cl = clusterIdx.map { Int($0[i]) } ?? 0
            let sym = Int(symbols[i])
            guard cl < tables.count else {
                throw ANSTokenStreamWriterError.clusterOutOfRange(cl, max: tables.count - 1)
            }
            let enc = tables[cl]
            guard sym < enc.symbols.count else {
                throw ANSTokenStreamWriterError.symbolHasZeroFrequency(
                    cluster: cl, symbol: sym)
            }
            let info = enc.symbols[sym]
            let f = info.freq
            guard f > 0 else {
                throw ANSTokenStreamWriterError.symbolHasZeroFrequency(
                    cluster: cl, symbol: sym)
            }
            if (state >> renormShift) >= f {
                refills += 1
                state >>= 16
            }
            let division = ANSReciprocalDivision.divide(state, frequency: f, reciprocal: info.reciprocal)
            state = (division.quotient &<< logTab)
                &+ enc.slotForResidue[Int(info.residueStart &+ division.remainder)]
            i -= 1
        }
        return refills
    }
}
