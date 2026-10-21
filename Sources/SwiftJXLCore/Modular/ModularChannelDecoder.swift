// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift 57e81cb9e2411d1efac435b429a306a031744c1e, Sources/JXLSwift/Modular/ModularChannelDecoder.swift.
// ModularChannelDecoder — drives the per-pixel decode loop for one
// Modular channel using a decoded MA-tree + a token stream reader.
//
// ISO/IEC 18181-1 §C.7 (libjxl `lib/jxl/modular/encoding/encoding.cc::
// DecodeModularChannelMAANS`). For each pixel `(x, y)`, the decoder:
//
//   1. Reads the 4-/6-neighbour patch from the partial channel buffer.
//   2. Computes the WP property from the running weighted-predictor
//      state, then the 16 standard properties (`ModularProperties`).
//   3. Walks the MA-tree to find the leaf node whose context governs
//      this pixel's residual (`ModularTree.walk`).
//   4. Pulls a HybridUint-decoded token from the post-tree
//      `TokenStreamReader` at `context = leaf.leafId`.
//   5. Recovers the signed residual: `r = unpackSigned(token) * leaf.multiplier`.
//   6. Applies the leaf's predictor (with `leaf.predictorOffset` added):
//      `pixel = predictorOutput + leaf.predictorOffset + r`. Predictor
//      6 (Weighted) sources its prediction from the WP state machine.
//   7. Updates the WP state with the actual decoded pixel value.
//
// **Edge fall-backs** for prediction neighbours follow `Neighbourhood.
// init(at:_:in:width:)`'s spec-aligned rules: missing W/N substitute
// the available neighbour or 0. **Property-computation** neighbours
// substitute 0 (matching libjxl `FillProperties`).
//
// The decoder does NOT apply Modular Transforms (RCT, Squeeze,
// Palette) — those operate on the assembled channel arrays as a
// post-step (`Modular/RCT.swift`, `Squeeze.swift`). This component
// only fills the raw per-channel sample arrays the spec calls for
// before the inverse transform pass.

import Foundation

package enum ModularChannelDecoderError: Error, Sendable {
    case invalidPredictor(UInt32)
    case tokenReader(TokenStreamReaderError)
    case treeWalk(ModularTreeError)
    case tokenOutOfRange(token: UInt32, leafId: Int)
    /// Wraps a token-read error with the (x, y) position where it
    /// occurred — useful for diagnostics when the decoder gives up.
    case tokenAtPosition(x: Int, y: Int, channel: Int32, inner: TokenStreamReaderError)
}

/// Decode one Modular channel. `width × height` pixel values fill
/// `out` in row-major order. `staticChannel` and `groupId` are the
/// values libjxl uses for properties 0 and 1 — pass the correct
/// indices so trees branching on those properties decode correctly.
/// `wpHeader` parameterises the weighted predictor (predictor 6 +
/// property 15); pass the parsed `WeightedPredictorHeader` from the
/// frame's `GroupHeader`.
package func decodeModularChannel<Storage: ModularSampleBuffer>(
    width: Int, height: Int,
    staticChannel: Int32, groupId: Int32,
    tree: ModularTree,
    stream: inout TokenStreamReader,
    from r: inout BitReader,
    wpHeader: WeightedPredictorHeader = .default,
    sampleMaximum: Int32? = nil,
    out: inout Storage
) throws {
    let (count, overflow) = width.multipliedReportingOverflow(by: height)
    guard width > 0, height > 0, !overflow, count == out.count, !tree.nodes.isEmpty else {
        throw BitstreamError.malformedValue("Invalid channel geometry or tree")
    }
    // A single gradient leaf does not consult properties or WP state. Dispatch
    // once per channel so its loop reads only the three required neighbours.
    if tree.nodes.count == 1, tree.nodes[0].isLeaf, tree.nodes[0].rawPredictor == 5 {
        try decodeSingleLeafGradient(width: width, height: height, staticChannel: staticChannel,
            leaf: tree.nodes[0], stream: &stream, from: &r,
            sampleMaximum: sampleMaximum, out: &out)
        return
    }
    if tree.nodes.count == 1, tree.nodes[0].isLeaf, tree.nodes[0].rawPredictor == 0 {
        try decodeSingleLeafZero(width: width, height: height, staticChannel: staticChannel,
            leaf: tree.nodes[0], stream: &stream, from: &r,
            sampleMaximum: sampleMaximum, out: &out)
        return
    }
    var wp = WeightedPredictor(header: wpHeader, xsize: width)
    // Reused 16-element properties array — allocating a fresh
    // `[Int32]` per pixel was a measurable hot spot.
    var props = [Int32](repeating: 0, count: 16)
    // Tree-walk fast path: when there's exactly one leaf, every
    // pixel routes to that leaf with no property lookup needed.
    let isSingleLeafTree = (tree.nodes.count == 1 && tree.nodes[0].isLeaf)
    let singleLeaf = tree.nodes[0]
    // WP fast-path: if no leaf uses predictor 6 (Weighted) AND no
    // decision node branches on property 15 (the WP property), we
    // can skip both `wp.propertyValue` and the heavyweight
    // `wp.predict`/`wp.update` entirely. libjxl makes the same
    // decision via its `is_wp_only` / `tree_has_wp_prop_or_pred`
    // flags in `DecodeModularChannelMAANS`.
    var treeUsesWP = false
    for node in tree.nodes {
        if node.isLeaf {
            if node.rawPredictor == 6 { treeUsesWP = true; break }
        } else if node.property == 15 {
            treeUsesWP = true; break
        }
    }
    for y in 0..<height {
        try Task.checkCancellation()
        let rowBase = out.rowAddress(y, width: width)
        let prevRow = y > 0 ? out.rowAddress(y - 1, width: width) : rowBase
        let prev2Row = y > 1 ? out.rowAddress(y - 2, width: width) : prevRow
        for x in 0..<width {
            // libjxl edge fall-backs (per `lib/jxl/modular/encoding/
            // context_predict.h::Predict`):
            //   left:     x>0 ? pp[-1] : (y>0 ? pp[-onerow] : 0)
            //   top:      y>0 ? pp[-onerow] : left
            //   topleft:  (x && y) ? pp[-1-onerow] : left
            //   topright: (x+1<w && y) ? pp[1-onerow] : top
            //   leftleft: x>1 ? pp[-2] : left
            //   toptop:   y>1 ? pp[-2*onerow] : top
            let left: Int32
            if x > 0 {
                left = out[row: rowBase, column: x - 1]
            } else if y > 0 {
                left = out[row: prevRow, column: x]
            } else {
                left = 0
            }
            let top: Int32 = y > 0 ? out[row: prevRow, column: x] : left
            let topLeft: Int32 = (x > 0 && y > 0)
                ? out[row: prevRow, column: x - 1] : left
            let topRight: Int32 = (x + 1 < width && y > 0)
                ? out[row: prevRow, column: x + 1] : top
            let leftLeft: Int32 = x > 1 ? out[row: rowBase, column: x - 2] : left
            let topTop: Int32 = y > 1 ? out[row: prev2Row, column: x] : top
            // Property 15 (WP property) only needed when the tree
            // branches on it OR uses predictor 6 — `treeUsesWP`
            // captures both. Skipping `wp.propertyValue` for
            // non-WP trees saves a per-pixel function call.
            let wpProp: Int32 = treeUsesWP
                ? wp.propertyValue(x: x, y: y, xsize: width)
                : 0
            let leaf: ModularTreeNode
            if isSingleLeafTree {
                // Skip the property fill + tree walk entirely.
                leaf = singleLeaf
            } else {
                fillModularProperties(
                    into: &props,
                    staticChannel: staticChannel, groupId: groupId,
                    x: Int32(x), y: Int32(y),
                    top: top, left: left,
                    topLeft: topLeft, topRight: topRight,
                    leftLeft: leftLeft, topTop: topTop,
                    wpProperty: wpProp
                )
                do { leaf = try tree.walk(properties: props) }
                catch let e as ModularTreeError {
                    throw ModularChannelDecoderError.treeWalk(e)
                }
            }
            let token: UInt32
            do {
                token = try stream.readToken(
                    context: leaf.leafId, from: &r
                )
            } catch let e as TokenStreamReaderError {
                throw ModularChannelDecoderError.tokenAtPosition(
                    x: x, y: y, channel: staticChannel, inner: e
                )
            }
            // Predictor neighbourhood — substitute available
            // neighbours at edges (different rules from properties).
            let nbh = Neighbourhood(
                w: left, n: top, nw: topLeft, ne: topRight,
                ww: leftLeft, nn: topTop
            )
            // Run WP only when the tree might consult it. For the
            // common default-tree case (single leaf, predictor 5
            // = Gradient) WP is dead work and skipping it gives a
            // significant per-pixel speedup.
            let wpPred: Int32
            if treeUsesWP {
                wpPred = wp.predict(
                    x: x, y: y, xsize: width,
                    n: top, w: left,
                    ne: topRight, nw: topLeft, nn: topTop
                )
            } else {
                wpPred = 0
            }
            let predicted = applyLibjxlPredictor(
                raw: leaf.rawPredictor, neighbourhood: nbh,
                wpResult: wpPred
            )
            let signedRes = ZigZag.unpack(token)
            let scaled = Int32(truncatingIfNeeded:
                Int64(signedRes) &* Int64(leaf.multiplier))
            let value = Int32(truncatingIfNeeded:
                Int64(predicted)
                &+ Int64(leaf.predictorOffset)
                &+ Int64(scaled))
            if let sampleMaximum, value < 0 || value > sampleMaximum {
                throw BitstreamError.malformedValue("Sample outside declared precision")
            }
            out[row: rowBase, column: x] = value
            if treeUsesWP {
                wp.update(actual: value, x: x, y: y, xsize: width)
            }
        }
    }
}


private final class ModularReaderContext: Sendable {
    let budget: ScalarOperationBudget?
    let deadline: ContinuousClock.Instant

    init(budget: ScalarOperationBudget?, deadline: ContinuousClock.Instant) {
        self.budget = budget
        self.deadline = budget.map { min(deadline, $0.deadline) } ?? deadline
    }

    @inline(never)
    func checkCancellationAndDeadline() throws {
        try BitReader.checkCancellationAndDeadline(budget: budget, deadline: deadline)
    }
}

private struct SingleContextANSReader {
    let flatSlotsBase: UnsafePointer<UInt64>
    let splitExponent: Int
    let msbInToken: Int
    let lsbInToken: Int
    let lsbInTokenU32: UInt32
    let msbLsb: UInt32
    let lsbMask: UInt32
    let msbMask: UInt32
    let splitThreshold: UInt32
    let simpleConfig: Bool
    let bytesBase: UnsafePointer<UInt8>?
    let bytesCount: Int
    let totalBits: Int
    let baseBitOffset: Int
    var bitBuf: UInt64
    var bitCount: Int
    var nextByte: Int
    var operations: Int
    var state: UInt32
    var initialised: Bool

    var currentPos: Int {
        baseBitOffset &+ (nextByte &* 8) &- bitCount
    }

    @inline(never)
    static func throwRecordedError(
        rawCode: Int64, pos: Int, totalBits: Int,
        x: Int, y: Int, channel: Int32
    ) throws -> Never {
        let inner: TokenStreamReaderError
        if rawCode <= -1000 {
            let requested = Int(-1000 &- rawCode)
            inner = .bitstream(.tooManyBits(requested: requested, max: 32))
        } else {
            let needed = Int(-rawCode)
            let rem = pos >= 0 && pos <= totalBits ? totalBits - pos : 0
            inner = .bitstream(.outOfBounds(needed: needed, remaining: rem))
        }
        throw ModularChannelDecoderError.tokenAtPosition(
            x: x, y: y, channel: channel, inner: inner
        )
    }

    @inline(__always)
    func throwError(_ rawCode: Int64, x: Int, y: Int, channel: Int32) throws -> Never {
        try Self.throwRecordedError(
            rawCode: rawCode, pos: currentPos, totalBits: totalBits,
            x: x, y: y, channel: channel
        )
    }

    @inline(never)
    private static func refillTailStatic(
        bytesBase: UnsafePointer<UInt8>?,
        bytesCount: Int,
        bitBuf: UInt64,
        bitCount: Int,
        nextByte: Int
    ) -> (bitBuf: UInt64, bitCount: Int, nextByte: Int) {
        guard let base = bytesBase, nextByte < bytesCount, bitCount <= 56 else {
            return (bitBuf, bitCount, nextByte)
        }
        var buf = bitBuf
        var cnt = bitCount
        var idx = nextByte
        buf |= UInt64(base[idx]) &<< UInt64(truncatingIfNeeded: cnt)
        idx &+= 1
        cnt &+= 8
        if cnt <= 56, idx < bytesCount {
            buf |= UInt64(base[idx]) &<< UInt64(truncatingIfNeeded: cnt)
            idx &+= 1
            cnt &+= 8
            if cnt <= 56, idx < bytesCount {
                buf |= UInt64(base[idx]) &<< UInt64(truncatingIfNeeded: cnt)
                idx &+= 1
                cnt &+= 8
            }
        }
        return (buf, cnt, idx)
    }

    @inline(__always)
    private mutating func refill() {
        if bitCount <= 32, nextByte &+ 4 <= bytesCount, let base = bytesBase {
            let word = UnsafeRawPointer(base.advanced(by: nextByte)).loadUnaligned(as: UInt32.self)
            bitBuf |= UInt64(UInt32(littleEndian: word)) &<< UInt64(truncatingIfNeeded: bitCount)
            nextByte &+= 4
            bitCount &+= 32
        } else if nextByte < bytesCount {
            let res = Self.refillTailStatic(
                bytesBase: bytesBase,
                bytesCount: bytesCount,
                bitBuf: bitBuf,
                bitCount: bitCount,
                nextByte: nextByte
            )
            bitBuf = res.bitBuf
            bitCount = res.bitCount
            nextByte = res.nextByte
        }
    }

    @inline(__always)
    private mutating func readBitsFast(_ count: Int) -> Int64 {
        if UInt(bitPattern: count) > 32 {
            return -1000 &- Int64(count)
        }
        if count == 0 { return 0 }
        if count > bitCount {
            refill()
            if count > bitCount {
                return -Int64(count)
            }
        }
        let u = UInt64(truncatingIfNeeded: count)
        let mask = (UInt64(1) &<< u) &- 1
        let value = UInt32(truncatingIfNeeded: bitBuf & mask)
        bitBuf &>>= u
        bitCount &-= count
        return Int64(value)
    }

    @inline(__always)
    mutating func ensureInitialised(channel: Int32, context: ModularReaderContext) throws {
        if operations == 0 {
            operations = 1
            try context.checkCancellationAndDeadline()
        }
        if !initialised {
            let raw = readBitsFast(32)
            if raw < 0 {
                try throwError(raw, x: 0, y: 0, channel: channel)
            }
            state = UInt32(truncatingIfNeeded: raw)
            initialised = true
        }
    }

    @inline(never)
    private mutating func readNonSimpleHybridUint(_ symbol: UInt32) -> Int64 {
        let rest = symbol &- splitThreshold
        let nMinusSplit = Int(truncatingIfNeeded: rest &>> msbLsb)
        let n = nMinusSplit &+ splitExponent
        let nExtra = n &- msbInToken &- lsbInToken
        let extra: UInt32
        if nExtra > 0 {
            let rawExtra = readBitsFast(nExtra)
            if rawExtra < 0 { return rawExtra }
            extra = UInt32(truncatingIfNeeded: rawExtra)
        } else {
            extra = 0
        }
        let lsbBits = symbol & lsbMask
        let msbBits = (symbol &>> lsbInTokenU32) & msbMask
        let m: UInt32 =
            (msbBits &<< UInt32(truncatingIfNeeded: n &- msbInToken))
            | (extra &<< lsbInTokenU32)
            | lsbBits
        return Int64((UInt32(1) &<< UInt32(truncatingIfNeeded: n)) &+ m)
    }

    @inline(__always)
    mutating func readTokenFast() -> Int64 {
        let slot = state & (ANSConstants.tabSize - 1)
        let packed = flatSlotsBase[Int(truncatingIfNeeded: slot)]
        let offsetPlusP = UInt32(truncatingIfNeeded: packed & 0xFFFF)
        let symbol = UInt32(truncatingIfNeeded: (packed &>> 16) & 0xFFFF)
        let freq = UInt32(truncatingIfNeeded: packed &>> 32)
        state = freq &* (state &>> UInt32(ANSConstants.logTabSize)) &+ offsetPlusP
        if state < ANSConstants.stateLowerBound {
            if bitCount < 16 {
                refill()
                if bitCount < 16 {
                    return -16
                }
            }
            let w = UInt32(truncatingIfNeeded: bitBuf & 0xFFFF)
            bitBuf &>>= 16
            bitCount &-= 16
            state = (state &<< 16) | w
        }
        if symbol < splitThreshold {
            return Int64(symbol)
        }
        if simpleConfig {
            let n = splitExponent &+ Int(truncatingIfNeeded: symbol &- splitThreshold)
            if n == 0 { return 1 }
            let low = readBitsFast(n)
            if low < 0 { return low }
            return Int64((UInt32(1) &<< UInt32(truncatingIfNeeded: n)) &+ UInt32(truncatingIfNeeded: low))
        }
        return readNonSimpleHybridUint(symbol)
    }
}

@inline(never)
private func decodeSingleLeafGradientANSCore<Storage: ModularSampleBuffer>(
    width: Int,
    height: Int,
    staticChannel: Int32,
    mul: Int32,
    offset: Int32,
    maxU: UInt32,
    flatSlotsBase: UnsafePointer<UInt64>,
    config: HybridUintConfig,
    bytesBase: UnsafePointer<UInt8>?,
    bytesCount: Int,
    context: ModularReaderContext,
    baseBitOffset: Int,
    bitBuf: UInt64,
    bitCount: Int,
    nextByte: Int,
    operations: Int,
    state: UInt32,
    initialised: Bool,
    out: inout Storage
) throws -> (bitBuf: UInt64, bitCount: Int, nextByte: Int, state: UInt32) {
    var s = SingleContextANSReader(
        flatSlotsBase: flatSlotsBase,
        splitExponent: config.splitExponent,
        msbInToken: config.msbInToken,
        lsbInToken: config.lsbInToken,
        lsbInTokenU32: UInt32(truncatingIfNeeded: config.lsbInToken),
        msbLsb: UInt32(truncatingIfNeeded: config.msbInToken + config.lsbInToken),
        lsbMask: config.lsbInToken == 0 ? 0 : (UInt32(1) &<< UInt32(truncatingIfNeeded: config.lsbInToken)) &- 1,
        msbMask: config.msbInToken == 0 ? 0 : (UInt32(1) &<< UInt32(truncatingIfNeeded: config.msbInToken)) &- 1,
        splitThreshold: UInt32(1) &<< UInt32(truncatingIfNeeded: config.splitExponent),
        simpleConfig: config.msbInToken == 0 && config.lsbInToken == 0,
        bytesBase: bytesBase,
        bytesCount: bytesCount,
        totalBits: bytesCount * 8,
        baseBitOffset: baseBitOffset,
        bitBuf: bitBuf,
        bitCount: bitCount,
        nextByte: nextByte,
        operations: operations,
        state: state,
        initialised: initialised
    )
    try s.ensureInitialised(channel: staticChannel, context: context)
    let row0 = out.rowAddress(0, width: width)
    var left0: Int32 = 0
    let oldOps0 = s.operations
    s.operations &+= width
    if ((oldOps0 &+ 1) & 255) == 0 || (oldOps0 &>> 8) != (s.operations &>> 8) {
        try context.checkCancellationAndDeadline()
    }
    var x0 = 0
    while x0 < width {
        if (x0 & 255) == 0, x0 != 0 {
            try context.checkCancellationAndDeadline()
        }
        let rawToken = s.readTokenFast()
        if rawToken < 0 {
            try s.throwError(rawToken, x: x0, y: 0, channel: staticChannel)
        }
        let token = UInt32(truncatingIfNeeded: rawToken)
        let value = left0 &+ offset &+ (ZigZag.unpack(token) &* mul)
        if UInt32(bitPattern: value) > maxU {
            throw BitstreamError.malformedValue("Sample outside declared precision")
        }
        out[row: row0, column: x0] = value
        left0 = value
        x0 &+= 1
    }
    if height > 1 {
        // The shortened median identity
        //   min(max(W + N - NW, min(W, N)), max(W, N)) == W + N - min(max(W, min(N, NW)), max(N, NW))
        // holds in Int32 when W + N - NW cannot overflow Int32. When sampleMaximum
        // bounds all stored samples to [0, 0x3FFF_FFFF], W + N - NW lies in
        // [-0x3FFF_FFFF, 0x7FFF_FFFE] subset of [Int32.min, Int32.max], making the
        // shortcut bit-identical to wrapping Int32 clamped-gradient arithmetic.
        // Transformed planes (sampleMaximum == nil, maxU == UInt32.max) retain the
        // exact wrapping Int32 recurrence below.
        let unitTransform = (mul == 1 && offset == 0 && maxU <= 0x3FFF_FFFF)
        for y in 1..<height {
            let rowBase = out.rowAddress(y, width: width)
            let prevRow = out.rowAddress(y - 1, width: width)
            let oldOps = s.operations
            s.operations &+= width
            if ((oldOps &+ 1) & 255) == 0 || (oldOps &>> 8) != (s.operations &>> 8) {
                try context.checkCancellationAndDeadline()
            }
            let rawToken0 = s.readTokenFast()
            if rawToken0 < 0 {
                try s.throwError(rawToken0, x: 0, y: y, channel: staticChannel)
            }
            let token0 = UInt32(truncatingIfNeeded: rawToken0)
            let top0 = out[row: prevRow, column: 0]
            let val0 = top0 &+ offset &+ (ZigZag.unpack(token0) &* mul)
            if UInt32(bitPattern: val0) > maxU {
                throw BitstreamError.malformedValue("Sample outside declared precision")
            }
            out[row: rowBase, column: 0] = val0
            var left = val0
            var topLeft = top0
            if unitTransform {
                var x = 1
                while x < width {
                    if (x & 255) == 0 {
                        try context.checkCancellationAndDeadline()
                    }
                    let rawToken = s.readTokenFast()
                    if rawToken < 0 {
                        try s.throwError(rawToken, x: x, y: y, channel: staticChannel)
                    }
                    let token = UInt32(truncatingIfNeeded: rawToken)
                    let top = out[row: prevRow, column: x]
                    let loT = min(top, topLeft)
                    let hiT = max(top, topLeft)
                    let residual = ZigZag.unpack(token)
                    let sum = left &+ (top &+ residual)
                    let clampedLeft = min(max(left, loT), hiT)
                    let value = sum &- clampedLeft
                    if UInt32(bitPattern: value) > maxU {
                        throw BitstreamError.malformedValue("Sample outside declared precision")
                    }
                    out[row: rowBase, column: x] = value
                    left = value
                    topLeft = top
                    x &+= 1
                }
            } else {
                var x = 1
                while x < width {
                    if (x & 255) == 0 {
                        try context.checkCancellationAndDeadline()
                    }
                    let rawToken = s.readTokenFast()
                    if rawToken < 0 {
                        try s.throwError(rawToken, x: x, y: y, channel: staticChannel)
                    }
                    let token = UInt32(truncatingIfNeeded: rawToken)
                    let top = out[row: prevRow, column: x]
                    let gradient = left &+ top &- topLeft
                    let lo = min(left, top)
                    let hi = max(left, top)
                    let predicted = min(max(gradient, lo), hi)
                    let value = predicted &+ offset &+ (ZigZag.unpack(token) &* mul)
                    if UInt32(bitPattern: value) > maxU {
                        throw BitstreamError.malformedValue("Sample outside declared precision")
                    }
                    out[row: rowBase, column: x] = value
                    left = value
                    topLeft = top
                    x &+= 1
                }
            }
        }
    }
    return (s.bitBuf, s.bitCount, s.nextByte, s.state)
}

@inline(never)
private func decodeSingleLeafZeroANSCore<Storage: ModularSampleBuffer>(
    width: Int,
    height: Int,
    staticChannel: Int32,
    mul: Int32,
    offset: Int32,
    maxU: UInt32,
    flatSlotsBase: UnsafePointer<UInt64>,
    config: HybridUintConfig,
    bytesBase: UnsafePointer<UInt8>?,
    bytesCount: Int,
    context: ModularReaderContext,
    baseBitOffset: Int,
    bitBuf: UInt64,
    bitCount: Int,
    nextByte: Int,
    operations: Int,
    state: UInt32,
    initialised: Bool,
    out: inout Storage
) throws -> (bitBuf: UInt64, bitCount: Int, nextByte: Int, state: UInt32) {
    var s = SingleContextANSReader(
        flatSlotsBase: flatSlotsBase,
        splitExponent: config.splitExponent,
        msbInToken: config.msbInToken,
        lsbInToken: config.lsbInToken,
        lsbInTokenU32: UInt32(truncatingIfNeeded: config.lsbInToken),
        msbLsb: UInt32(truncatingIfNeeded: config.msbInToken + config.lsbInToken),
        lsbMask: config.lsbInToken == 0 ? 0 : (UInt32(1) &<< UInt32(truncatingIfNeeded: config.lsbInToken)) &- 1,
        msbMask: config.msbInToken == 0 ? 0 : (UInt32(1) &<< UInt32(truncatingIfNeeded: config.msbInToken)) &- 1,
        splitThreshold: UInt32(1) &<< UInt32(truncatingIfNeeded: config.splitExponent),
        simpleConfig: config.msbInToken == 0 && config.lsbInToken == 0,
        bytesBase: bytesBase,
        bytesCount: bytesCount,
        totalBits: bytesCount * 8,
        baseBitOffset: baseBitOffset,
        bitBuf: bitBuf,
        bitCount: bitCount,
        nextByte: nextByte,
        operations: operations,
        state: state,
        initialised: initialised
    )
    try s.ensureInitialised(channel: staticChannel, context: context)
    for y in 0..<height {
        let row = out.rowAddress(y, width: width)
        let oldOps = s.operations
        s.operations &+= width
        if ((oldOps &+ 1) & 255) == 0 || (oldOps &>> 8) != (s.operations &>> 8) {
            try context.checkCancellationAndDeadline()
        }
        var x = 0
        while x < width {
            if (x & 255) == 0, x != 0 {
                try context.checkCancellationAndDeadline()
            }
            let rawToken = s.readTokenFast()
            if rawToken < 0 {
                try s.throwError(rawToken, x: x, y: y, channel: staticChannel)
            }
            let token = UInt32(truncatingIfNeeded: rawToken)
            let value = offset &+ (ZigZag.unpack(token) &* mul)
            if UInt32(bitPattern: value) > maxU {
                throw BitstreamError.malformedValue("Sample outside declared precision")
            }
            out[row: row, column: x] = value
            x &+= 1
        }
    }
    return (s.bitBuf, s.bitCount, s.nextByte, s.state)
}

/// Specialisation of the generic loop, preserving wrapping residual arithmetic,
/// precision rejection and token/row cancellation checks. The caller has checked
/// dimensions and sample count. Storage remains in its synchronous owner borrow.
private func decodeSingleLeafGradient<Storage: ModularSampleBuffer>(
    width: Int, height: Int, staticChannel: Int32, leaf: ModularTreeNode,
    stream: inout TokenStreamReader, from r: inout BitReader,
    sampleMaximum: Int32?, out: inout Storage
) throws {
    let mul = Int32(truncatingIfNeeded: leaf.multiplier)
    let offset = Int32(truncatingIfNeeded: leaf.predictorOffset)
    let maxU = sampleMaximum.map { UInt32(bitPattern: $0) } ?? UInt32.max
    if stream.canUseSingleContextANS(context: leaf.leafId) {
        let (alias, config, initialState, initialInit) = stream.singleContextANSCluster(context: leaf.leafId)
        let flatSlots = alias.buildFlatSlots()
        let baseBitOffset = r.pos &+ r.bitCount &- (r.nextByte &* 8)
        let res = try flatSlots.withUnsafeBufferPointer { slotsPtr in
            try r.bytes.withUnsafeBufferPointer { bytesPtr in
                try decodeSingleLeafGradientANSCore(
                    width: width,
                    height: height,
                    staticChannel: staticChannel,
                    mul: mul,
                    offset: offset,
                    maxU: maxU,
                    flatSlotsBase: slotsPtr.baseAddress!,
                    config: config,
                    bytesBase: bytesPtr.baseAddress,
                    bytesCount: bytesPtr.count,
                    context: ModularReaderContext(budget: r.budget, deadline: r.deadline),
                    baseBitOffset: baseBitOffset,
                    bitBuf: r.bitBuf,
                    bitCount: r.bitCount,
                    nextByte: r.nextByte,
                    operations: r.operations,
                    state: initialState,
                    initialised: initialInit,
                    out: &out
                )
            }
        }
        r.pos = baseBitOffset &+ (res.nextByte &* 8) &- res.bitCount
        r.bitBuf = res.bitBuf
        r.bitCount = res.bitCount
        r.nextByte = res.nextByte
        r.operations = (r.operations == 0 ? 1 : r.operations) &+ (width &* height)
        stream.updateSingleContextANSState(res.state, initialised: true)
        return
    }
    for y in 0..<height {
        try Task.checkCancellation()
        let rowBase = out.rowAddress(y, width: width)
        let prevRow = y > 0 ? out.rowAddress(y - 1, width: width) : rowBase
        var left: Int32 = 0
        var topLeft: Int32 = 0
        for x in 0..<width {
            let top: Int32 = y > 0 ? out[row: prevRow, column: x] : left
            let predicted: Int32
            if x == 0 || y == 0 {
                predicted = top
            } else {
                let gradient = left &+ top &- topLeft
                predicted = min(max(gradient, min(left, top)), max(left, top))
            }
            let token: UInt32
            do { token = try stream.readToken(context: leaf.leafId, from: &r) }
            catch let error as TokenStreamReaderError {
                throw ModularChannelDecoderError.tokenAtPosition(
                    x: x, y: y, channel: staticChannel, inner: error)
            }
            let value = predicted &+ offset &+ (ZigZag.unpack(token) &* mul)
            if UInt32(bitPattern: value) > maxU {
                throw BitstreamError.malformedValue("Sample outside declared precision")
            }
            out[row: rowBase, column: x] = value
            left = value
            topLeft = top
        }
    }
}

/// A zero predictor has no sample dependencies. Read every token even for a
/// zero-bit prefix alphabet: this preserves LZ77/history, truncation errors and
/// the reader's cancellation/deadline checkpoint at most every 256 operations.
private func decodeSingleLeafZero<Storage: ModularSampleBuffer>(
    width: Int, height: Int, staticChannel: Int32, leaf: ModularTreeNode,
    stream: inout TokenStreamReader, from r: inout BitReader,
    sampleMaximum: Int32?, out: inout Storage
) throws {
    let mul = Int32(truncatingIfNeeded: leaf.multiplier)
    let offset = Int32(truncatingIfNeeded: leaf.predictorOffset)
    let maxU = sampleMaximum.map { UInt32(bitPattern: $0) } ?? UInt32.max
    if stream.canUseSingleContextANS(context: leaf.leafId) {
        let (alias, config, initialState, initialInit) = stream.singleContextANSCluster(context: leaf.leafId)
        let flatSlots = alias.buildFlatSlots()
        let baseBitOffset = r.pos &+ r.bitCount &- (r.nextByte &* 8)
        let res = try flatSlots.withUnsafeBufferPointer { slotsPtr in
            try r.bytes.withUnsafeBufferPointer { bytesPtr in
                try decodeSingleLeafZeroANSCore(
                    width: width,
                    height: height,
                    staticChannel: staticChannel,
                    mul: mul,
                    offset: offset,
                    maxU: maxU,
                    flatSlotsBase: slotsPtr.baseAddress!,
                    config: config,
                    bytesBase: bytesPtr.baseAddress,
                    bytesCount: bytesPtr.count,
                    context: ModularReaderContext(budget: r.budget, deadline: r.deadline),
                    baseBitOffset: baseBitOffset,
                    bitBuf: r.bitBuf,
                    bitCount: r.bitCount,
                    nextByte: r.nextByte,
                    operations: r.operations,
                    state: initialState,
                    initialised: initialInit,
                    out: &out
                )
            }
        }
        r.pos = baseBitOffset &+ (res.nextByte &* 8) &- res.bitCount
        r.bitBuf = res.bitBuf
        r.bitCount = res.bitCount
        r.nextByte = res.nextByte
        r.operations = (r.operations == 0 ? 1 : r.operations) &+ (width &* height)
        stream.updateSingleContextANSState(res.state, initialised: true)
        return
    }
    for y in 0..<height {
        try Task.checkCancellation()
        let row = out.rowAddress(y, width: width)
        for x in 0..<width {
            let token: UInt32
            do { token = try stream.readToken(context: leaf.leafId, from: &r) }
            catch let error as TokenStreamReaderError {
                throw ModularChannelDecoderError.tokenAtPosition(
                    x: x, y: y, channel: staticChannel, inner: error)
            }
            let value = offset &+ (ZigZag.unpack(token) &* mul)
            if UInt32(bitPattern: value) > maxU {
                throw BitstreamError.malformedValue("Sample outside declared precision")
            }
            out[row: row, column: x] = value
        }
    }
}

/// Convenience: decode one Modular channel into a fresh `[Int32]`
/// buffer. See `decodeModularChannel(...)` for parameter semantics.
package func decodeModularChannel(
    width: Int, height: Int,
    staticChannel: Int32, groupId: Int32,
    tree: ModularTree,
    stream: inout TokenStreamReader,
    from r: inout BitReader,
    wpHeader: WeightedPredictorHeader = .default,
    sampleMaximum: Int32? = nil
) throws -> [Int32] {
    let (count, overflow) = width.multipliedReportingOverflow(by: height)
    guard width > 0, height > 0, !overflow, count <= 1024 * 1024 else {
        throw BitstreamError.malformedValue("Channel allocation limit exceeded")
    }
    var buf = [Int32](repeating: 0, count: count)
    try buf.withUnsafeMutableBufferPointer { ptr in
        var target = ptr
        try decodeModularChannel(
            width: width, height: height,
            staticChannel: staticChannel, groupId: groupId,
            tree: tree, stream: &stream, from: &r,
            wpHeader: wpHeader, sampleMaximum: sampleMaximum, out: &target
        )
    }
    return buf
}

/// One channel's geometry for `decodeAllChannels(...)`. `width` and
/// `height` are post-shift dimensions (i.e., already accounting for
/// `hshift` / `vshift` in chroma-subsampled inputs).
package struct ModularChannelGeometry: Sendable, Equatable {
    package let width: Int
    package let height: Int
    package init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Decode every channel listed in `channels` from a single shared
/// `TokenStreamReader`. Each channel gets its own fresh
/// `WeightedPredictor` state (the WP arrays are per-channel, not
/// shared). Channel index becomes property 0 (`staticChannel`); pass
/// the same `groupId` for all channels in a group.
///
/// Returns one `[Int32]` buffer per input channel, in the same order.
package func decodeAllChannels(
    channels: [ModularChannelGeometry],
    groupId: Int32,
    tree: ModularTree,
    stream: inout TokenStreamReader,
    from r: inout BitReader,
    wpHeader: WeightedPredictorHeader = .default
) throws -> [[Int32]] {
    var out = [[Int32]]()
    out.reserveCapacity(channels.count)
    for (i, g) in channels.enumerated() {
        let buf = try decodeModularChannel(
            width: g.width, height: g.height,
            staticChannel: Int32(i), groupId: groupId,
            tree: tree, stream: &stream, from: &r, wpHeader: wpHeader
        )
        out.append(buf)
    }
    return out
}
