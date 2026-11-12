// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

package enum TokenStreamReaderError: Error, Sendable, Equatable {
    case contextOutOfRange(Int, max: Int)
    case clusterOutOfRange(Int, max: Int)
    case prefix(PrefixCodeError)
    case ans(ANSError)
    case alias(AliasTableError)
    case bitstream(BitstreamError)
    case ansFinalStateMismatch(got: UInt32)
    case lz77InvalidDistance(UInt32, historySize: Int)
    case lz77InvalidLength
}

/// Clean-room entropy token stream reader implementing ISO/IEC 18181-1:2024
/// Clauses 7.1–7.4 (Prefix codes, rANS with alias table lookup, HybridUint
/// integer expansion, and LZ77 sliding-window + 2D special distances).
package struct TokenStreamReader: Sendable {
    package static let lz77WindowSize: Int = 1 << 15
    private static let lz77WindowMask: Int = (1 << 15) - 1

    /// ISO/IEC 18181-1 Clause 7.4 Table 16 — 120 2D coordinate offsets `(dx, dy)`.
    private static let specialDistances: [(dx: Int, dy: Int)] = [
        (0, 1), (1, 0), (1, 1), (-1, 1),
        (0, 2), (2, 0), (1, 2), (-1, 2), (2, 1), (-2, 1), (2, 2), (-2, 2),
        (0, 3), (3, 0), (1, 3), (-1, 3), (3, 1), (-3, 1), (2, 3), (-2, 3), (3, 2), (-3, 2),
        (0, 4), (4, 0), (1, 4), (-1, 4), (4, 1), (-4, 1), (3, 3), (-3, 3), (2, 4), (-2, 4), (4, 2), (-4, 2),
        (0, 5), (3, 4), (-3, 4), (4, 3), (-4, 3), (5, 0), (1, 5), (-1, 5), (5, 1), (-5, 1), (2, 5), (-2, 5),
        (5, 2), (-5, 2), (4, 4), (-4, 4), (3, 5), (-3, 5), (5, 3), (-5, 3),
        (0, 6), (6, 0), (1, 6), (-1, 6), (6, 1), (-6, 1), (2, 6), (-2, 6), (6, 2), (-6, 2), (4, 5), (-4, 5),
        (5, 4), (-5, 4), (3, 6), (-3, 6), (6, 3), (-6, 3),
        (0, 7), (7, 0), (1, 7), (-1, 7), (5, 5), (-5, 5), (7, 1), (-7, 1), (4, 6), (-4, 6), (6, 4), (-6, 4),
        (2, 7), (-2, 7), (7, 2), (-7, 2), (3, 7), (-3, 7), (7, 3), (-7, 3), (5, 6), (-5, 6), (6, 5), (-6, 5),
        (8, 0), (4, 7), (-4, 7), (7, 4), (-7, 4), (8, 1), (8, 2), (6, 6), (-6, 6), (8, 3), (5, 7), (-5, 7),
        (7, 5), (-7, 5), (8, 4), (6, 7), (-6, 7), (7, 6), (-7, 6), (8, 5), (7, 7), (-7, 7), (8, 6), (8, 7)
    ]

    package let header: EntropySectionHeader
    package let codebook: MultiClusterCodebook
    package let distanceMultiplier: Int

    private let usePrefixCode: Bool
    private let lz77Enabled: Bool
    private let lz77MinSymbol: UInt32
    private let numContexts: Int
    private let numUintConfigs: Int
    private let ctxMap: [UInt8]
    private let uintConfigs: [HybridUintConfig]
    private let huffmanTables: [PrefixCodeTable]
    private let prefixDescriptors: [PrefixClusterDescriptor]
    private let flatPrefixLUT: [UInt32]
    private let numPrefixClusters: Int

    private var ansDecoder: ANSStreamDecoder
    private let ansUnavailable: Bool
    private let ansInitError: AliasTableError?
    private let numANSClusters: Int
    private let canFastANS: Bool
    private var ansState: UInt32 = 0
    private var ansInitialised: Bool = false

    private var lz77Window: [UInt32]
    private var lz77NumDecoded: Int = 0
    private var lz77NumToCopy: UInt32 = 0
    private var lz77CopyPos: Int = 0

    package init(
        header: EntropySectionHeader,
        codebook: MultiClusterCodebook,
        distanceMultiplier: Int = 0
    ) {
        self.header = header
        self.codebook = codebook
        self.distanceMultiplier = max(0, distanceMultiplier)
        self.usePrefixCode = header.usePrefixCode
        self.lz77Enabled = header.lz77.enabled
        self.lz77MinSymbol = header.lz77.minSymbol
        self.numContexts = header.contextMap.numContexts
        self.numUintConfigs = header.uintConfigs.count
        self.ctxMap = header.contextMap.map
        self.uintConfigs = header.uintConfigs
        self.huffmanTables = codebook.huffmanTables
        self.prefixDescriptors = codebook.prefixDescriptors
        self.flatPrefixLUT = codebook.flatPrefixLUT
        self.numPrefixClusters = codebook.prefixDescriptors.count
        self.lz77Window = header.lz77.enabled
            ? [UInt32](repeating: 0, count: Self.lz77WindowSize)
            : []

        let dec: ANSStreamDecoder
        let unavail: Bool
        let initErr: AliasTableError?
        if header.usePrefixCode {
            dec = ANSStreamDecoder(distributions: [])
            unavail = true
            initErr = nil
        } else if let prebuilt = codebook.prebuiltANSDecoder {
            dec = prebuilt
            unavail = false
            initErr = nil
        } else if let prebuiltErr = codebook.prebuiltANSError {
            dec = ANSStreamDecoder(distributions: [])
            unavail = true
            initErr = prebuiltErr
        } else {
            do {
                dec = try ANSStreamDecoder(
                    counts: codebook.ansCounts,
                    logAlphaSize: header.logAlphaSize
                )
                unavail = false
                initErr = nil
            } catch let error as AliasTableError {
                dec = ANSStreamDecoder(distributions: [])
                unavail = true
                initErr = error
            } catch {
                dec = ANSStreamDecoder(distributions: [])
                unavail = true
                initErr = .sumNotEqualRange
            }
        }
        self.ansDecoder = dec
        self.ansUnavailable = unavail
        self.ansInitError = initErr
        self.numANSClusters = dec.aliasTables.count
        self.canFastANS = !header.usePrefixCode && !unavail && initErr == nil
    }

    @inline(__always)
    package func canUseSingleContextANS(context: Int) -> Bool {
        guard !header.usePrefixCode,
              !header.lz77.enabled,
              !ansUnavailable,
              ansInitError == nil,
              context >= 0,
              context < header.contextMap.numContexts else {
            return false
        }
        let cluster = Int(header.contextMap.map[context])
        return cluster >= 0
            && cluster < ansDecoder.aliasTables.count
            && cluster < header.uintConfigs.count
    }

    @inline(__always)
    package func singleContextANSCluster(
        context: Int
    ) -> (AliasTable, HybridUintConfig, UInt32, Bool) {
        let cluster = Int(header.contextMap.map[context])
        return (
            ansDecoder.aliasTables[cluster],
            header.uintConfigs[cluster],
            ansState,
            ansInitialised
        )
    }

    @inline(__always)
    package func singleContextANSFlatCluster(
        context: Int
    ) -> (flatSlots: [UInt64], clusterOffset: Int, config: HybridUintConfig, state: UInt32, initialised: Bool) {
        let cluster = Int(header.contextMap.map[context])
        return (
            ansDecoder.flatSlots,
            cluster &<< ANSConstants.logTabSize,
            header.uintConfigs[cluster],
            ansState,
            ansInitialised
        )
    }

    @inline(__always)
    package func canUseSingleContextPrefix(context: Int) -> Bool {
        guard header.usePrefixCode,
              !header.lz77.enabled,
              lz77NumToCopy == 0,
              context >= 0,
              context < header.contextMap.numContexts else {
            return false
        }
        let cluster = Int(header.contextMap.map[context])
        return cluster >= 0
            && cluster < header.uintConfigs.count
            && cluster < codebook.huffmanTables.count
    }

    @inline(__always)
    package func singleContextPrefixCluster(
        context: Int
    ) -> (table: PrefixCodeTable, config: HybridUintConfig) {
        let cluster = Int(header.contextMap.map[context])
        return (codebook.huffmanTables[cluster], header.uintConfigs[cluster])
    }

    @inline(__always)
    package func canUseMultiContextANS() -> Bool {
        guard !header.usePrefixCode,
              !header.lz77.enabled,
              lz77NumToCopy == 0,
              !ansUnavailable,
              ansInitError == nil else {
            return false
        }
        return ansDecoder.useAliasTables
    }

    @inline(__always)
    package func multiContextANSState() -> (
        flatSlots: [UInt64],
        ctxMap: [UInt8],
        uintConfigs: [HybridUintConfig],
        userCtxBound: Int,
        numHistograms: Int,
        state: UInt32,
        initialised: Bool
    ) {
        return (
            ansDecoder.flatSlots,
            header.contextMap.map,
            header.uintConfigs,
            header.contextMap.numContexts,
            header.uintConfigs.count,
            ansState,
            ansInitialised
        )
    }

    @inline(__always)
    package func canUseMultiContextPrefix() -> Bool {
        return header.usePrefixCode
            && !header.lz77.enabled
            && lz77NumToCopy == 0
            && codebook.huffmanTables.count == header.uintConfigs.count
    }

    @inline(__always)
    package func multiContextPrefixState() -> (
        tables: [PrefixCodeTable],
        ctxMap: [UInt8],
        uintConfigs: [HybridUintConfig],
        userCtxBound: Int,
        numHistograms: Int
    ) {
        return (
            codebook.huffmanTables,
            header.contextMap.map,
            header.uintConfigs,
            header.contextMap.numContexts,
            header.uintConfigs.count
        )
    }

    @inline(__always)
    package mutating func updateSingleContextANSState(
        _ state: UInt32,
        initialised: Bool
    ) {
        ansState = state
        ansInitialised = initialised
        ansDecoder.updateState(state, initialised: initialised)
    }

    @inline(never)
    private func readPrefixSymbol(
        cluster: Int,
        from r: inout BitReader
    ) throws -> UInt32 {
        guard cluster >= 0 && cluster < numPrefixClusters else {
            throw TokenStreamReaderError.clusterOutOfRange(
                cluster,
                max: numPrefixClusters - 1
            )
        }
        let desc = prefixDescriptors[cluster]
        let need = desc.usedMaxLength
        if need == 0 {
            return UInt32(desc.singleSymbol)
        }
        if r.bitCount < need {
            r.refill()
        }
        if r.bitCount >= need {
            let raw = Int(r.bitBuf & desc.usedMaxMask)
            let entry = flatPrefixLUT[desc.lutOffset &+ raw]
            let consumed = Int(entry &>> 16)
            r.bitBuf &>>= UInt64(consumed)
            r.bitCount &-= consumed
            r.pos &+= consumed
            return entry & 0xFFFF
        }
        do {
            let sym = try huffmanTables[cluster].decode(from: &r)
            return UInt32(sym)
        } catch let error as PrefixCodeError {
            throw TokenStreamReaderError.prefix(error)
        }
    }

    @inline(never)
    private mutating func readANSSymbol(
        cluster: Int,
        from r: inout BitReader
    ) throws -> UInt32 {
        if let err = ansInitError {
            throw TokenStreamReaderError.alias(err)
        }
        guard !ansUnavailable,
              cluster >= 0 && cluster < numANSClusters else {
            throw TokenStreamReaderError.clusterOutOfRange(
                cluster,
                max: numANSClusters - 1
            )
        }
        ansDecoder.updateState(ansState, initialised: ansInitialised)
        do {
            let sym = try ansDecoder.readSymbol(cluster: cluster, from: &r)
            ansState = ansDecoder.currentState
            ansInitialised = ansDecoder.hasInitialised
            return sym
        } catch let error as ANSError {
            ansState = ansDecoder.currentState
            ansInitialised = ansDecoder.hasInitialised
            throw TokenStreamReaderError.ans(error)
        } catch let error as BitstreamError {
            ansState = ansDecoder.currentState
            ansInitialised = ansDecoder.hasInitialised
            throw TokenStreamReaderError.bitstream(error)
        }
    }

    @inline(__always)
    private mutating func readRawSymbol(
        cluster: Int,
        from r: inout BitReader
    ) throws -> UInt32 {
        if usePrefixCode {
            return try readPrefixSymbol(cluster: cluster, from: &r)
        } else {
            return try readANSSymbol(cluster: cluster, from: &r)
        }
    }

    @inline(__always)
    private static func expandHybridUint(
        config: HybridUintConfig,
        token: UInt32,
        from r: inout BitReader
    ) throws -> UInt32 {
        do {
            return try config.decode(token: token, from: &r)
        } catch let error as BitstreamError {
            throw TokenStreamReaderError.bitstream(error)
        }
    }

    @inline(__always)
    package mutating func readTokenNoLZ77(
        context: Int,
        from r: inout BitReader,
        ctxMapPtr: UnsafePointer<UInt8>,
        uintConfigsPtr: UnsafePointer<HybridUintConfig>,
        flatSlotsPtr: UnsafePointer<UInt64>?,
        prefixDescPtr: UnsafePointer<PrefixClusterDescriptor>?,
        flatPrefixLUTPtr: UnsafePointer<UInt32>?
    ) throws -> UInt32 {
        try r.checkpoint()

        guard UInt(bitPattern: context) < UInt(bitPattern: numContexts) else {
            throw TokenStreamReaderError.contextOutOfRange(
                context,
                max: numContexts - 1
            )
        }
        let cluster = Int(ctxMapPtr[context])
        guard UInt(bitPattern: cluster) < UInt(bitPattern: numUintConfigs) else {
            throw TokenStreamReaderError.clusterOutOfRange(
                cluster,
                max: numUintConfigs - 1
            )
        }

        let token: UInt32
        if usePrefixCode {
            guard UInt(bitPattern: cluster) < UInt(bitPattern: numPrefixClusters),
                  let descPtr = prefixDescPtr else {
                throw TokenStreamReaderError.clusterOutOfRange(
                    cluster,
                    max: numPrefixClusters - 1
                )
            }
            let desc = descPtr[cluster]
            let need = desc.usedMaxLength
            if need == 0 {
                token = UInt32(desc.singleSymbol)
            } else {
                if r.bitCount < need {
                    r.refill()
                }
                if r.bitCount >= need, let lutPtr = flatPrefixLUTPtr {
                    let raw = Int(r.bitBuf & desc.usedMaxMask)
                    let entry = lutPtr[desc.lutOffset &+ raw]
                    let consumed = Int(entry &>> 16)
                    r.bitBuf &>>= UInt64(consumed)
                    r.bitCount &-= consumed
                    r.pos &+= consumed
                    token = entry & 0xFFFF
                } else {
                    token = try readPrefixSymbol(cluster: cluster, from: &r)
                }
            }
        } else if canFastANS, let slotsPtr = flatSlotsPtr,
                  UInt(bitPattern: cluster) < UInt(bitPattern: numANSClusters) {
            if !ansInitialised {
                do {
                    ansState = try r.read(bits: 32)
                    ansInitialised = true
                } catch let error as BitstreamError {
                    throw TokenStreamReaderError.bitstream(error)
                }
            }
            let logTab = UInt32(ANSConstants.logTabSize)
            var st = ansState
            let slot = st & (ANSConstants.tabSize - 1)
            let packed = slotsPtr[(cluster &<< ANSConstants.logTabSize) | Int(slot)]
            let offsetPlusP = UInt32(truncatingIfNeeded: packed & 0xFFFF)
            token = UInt32(truncatingIfNeeded: (packed &>> 16) & 0xFFFF)
            let freq = UInt32(truncatingIfNeeded: packed &>> 32)
            st = freq &* (st >> logTab) &+ offsetPlusP
            if st < ANSConstants.stateLowerBound {
                if r.bitCount < 16 {
                    r.refill()
                }
                if r.bitCount >= 16 {
                    let w = UInt32(truncatingIfNeeded: r.bitBuf & 0xFFFF)
                    r.bitBuf &>>= 16
                    r.bitCount &-= 16
                    r.pos &+= 16
                    st = (st << 16) | w
                } else {
                    do {
                        let w = try r.read(bits: 16)
                        st = (st << 16) | w
                    } catch let error as BitstreamError {
                        ansState = st
                        throw TokenStreamReaderError.bitstream(error)
                    }
                }
            }
            ansState = st
        } else {
            token = try readANSSymbol(cluster: cluster, from: &r)
        }

        let config = uintConfigsPtr[cluster]
        let split = UInt32(1) &<< UInt32(config.splitExponent)
        if token < split {
            return token
        }
        return try Self.expandHybridUint(
            config: config,
            token: token,
            from: &r
        )
    }

    @inline(__always)
    package mutating func readToken(
        context: Int,
        from r: inout BitReader
    ) throws -> UInt32 {
        try r.checkpoint()

        if lz77NumToCopy > 0 {
            lz77NumToCopy -= 1
            let copied = lz77Window[lz77CopyPos & Self.lz77WindowMask]
            lz77CopyPos &+= 1
            lz77Window[lz77NumDecoded & Self.lz77WindowMask] = copied
            lz77NumDecoded &+= 1
            return copied
        }

        guard context >= 0 && context < numContexts else {
            throw TokenStreamReaderError.contextOutOfRange(
                context,
                max: numContexts - 1
            )
        }
        let cluster = Int(ctxMap[context])
        guard cluster >= 0 && cluster < numUintConfigs else {
            throw TokenStreamReaderError.clusterOutOfRange(
                cluster,
                max: numUintConfigs - 1
            )
        }

        let token = usePrefixCode
            ? try readPrefixSymbol(cluster: cluster, from: &r)
            : try readANSSymbol(cluster: cluster, from: &r)

        if !lz77Enabled || token < lz77MinSymbol {
            let value = try Self.expandHybridUint(
                config: uintConfigs[cluster],
                token: token,
                from: &r
            )
            if lz77Enabled {
                lz77Window[lz77NumDecoded & Self.lz77WindowMask] = value
                lz77NumDecoded &+= 1
            }
            return value
        }

        // ISO/IEC 18181-1 Clause 7.4: LZ77 length-and-distance pair.
        let lengthToken = token &- header.lz77.minSymbol
        let baseLength = try Self.expandHybridUint(
            config: header.lz77.lengthUintConfig,
            token: lengthToken,
            from: &r
        )
        let (totalLength, lengthOverflow) = baseLength.addingReportingOverflow(
            header.lz77.minLength
        )
        guard !lengthOverflow, totalLength > 0 else {
            throw TokenStreamReaderError.lz77InvalidLength
        }

        let distanceContext = header.contextMap.numContexts - 1
        let distanceCluster = Int(header.contextMap.map[distanceContext])
        guard distanceCluster >= 0 && distanceCluster < header.uintConfigs.count else {
            throw TokenStreamReaderError.clusterOutOfRange(
                distanceCluster,
                max: header.uintConfigs.count - 1
            )
        }

        let distanceToken = try readRawSymbol(cluster: distanceCluster, from: &r)
        let rawDistance = try Self.expandHybridUint(
            config: header.uintConfigs[distanceCluster],
            token: distanceToken,
            from: &r
        )

        let historySize = min(lz77NumDecoded, Self.lz77WindowSize)
        let distance: UInt32
        if distanceMultiplier == 0 {
            distance = rawDistance &+ 1
        } else if rawDistance < 120 {
            let special = Self.specialDistances[Int(rawDistance)]
            let offset = Int64(special.dx) + Int64(special.dy) * Int64(distanceMultiplier)
            let clamped = max(Int64(1), offset)
            guard let exact = UInt32(exactly: clamped) else {
                throw TokenStreamReaderError.lz77InvalidDistance(0, historySize: historySize)
            }
            distance = exact
        } else {
            distance = rawDistance &- 119
        }

        guard distance >= 1 && distance <= UInt32(historySize) else {
            throw TokenStreamReaderError.lz77InvalidDistance(distance, historySize: historySize)
        }

        lz77CopyPos = (lz77NumDecoded - Int(distance)) & Self.lz77WindowMask
        lz77NumToCopy = totalLength - 1
        let firstCopied = lz77Window[lz77CopyPos]
        lz77CopyPos = (lz77CopyPos + 1) & Self.lz77WindowMask
        lz77Window[lz77NumDecoded & Self.lz77WindowMask] = firstCopied
        lz77NumDecoded &+= 1
        return firstCopied
    }

    /// Verify terminal state for an entropy section where tokens were read.
    package func finish() throws {
        if header.lz77.enabled && lz77NumToCopy != 0 {
            throw TokenStreamReaderError.lz77InvalidLength
        }
        if !header.usePrefixCode {
            if let err = ansInitError {
                throw TokenStreamReaderError.alias(err)
            }
            guard !ansUnavailable,
                  ansInitialised,
                  ansState == ANSConstants.initialState else {
                throw TokenStreamReaderError.ansFinalStateMismatch(
                    got: ansState
                )
            }
        }
    }

    /// Consume the 32-bit initial rANS state if no symbols were decoded in an
    /// ANS section, then verify the terminal rANS checksum (`0x130000`).
    package mutating func finish(from r: inout BitReader) throws {
        if !header.usePrefixCode, !ansUnavailable, !ansInitialised {
            do {
                let state = try r.read(bits: 32)
                ansState = state
                ansInitialised = true
                ansDecoder.updateState(state, initialised: true)
            } catch let error as BitstreamError {
                throw TokenStreamReaderError.bitstream(error)
            }
        }
        try finish()
    }
}
