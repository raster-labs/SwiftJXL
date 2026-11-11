// SPDX-License-Identifier: Apache-2.0
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

    private var ansDecoder: ANSStreamDecoder?
    private let ansInitError: AliasTableError?

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
        self.lz77Window = header.lz77.enabled
            ? [UInt32](repeating: 0, count: Self.lz77WindowSize)
            : []

        if header.usePrefixCode {
            self.ansDecoder = nil
            self.ansInitError = nil
        } else {
            do {
                self.ansDecoder = try ANSStreamDecoder(
                    counts: codebook.ansCounts,
                    logAlphaSize: header.logAlphaSize
                )
                self.ansInitError = nil
            } catch let error as AliasTableError {
                self.ansDecoder = nil
                self.ansInitError = error
            } catch {
                self.ansDecoder = nil
                self.ansInitError = .sumNotEqualRange
            }
        }
    }

    @inline(__always)
    package func canUseSingleContextANS(context: Int) -> Bool {
        guard !header.usePrefixCode,
              !header.lz77.enabled,
              ansInitError == nil,
              let ans = ansDecoder,
              context >= 0,
              context < header.contextMap.numContexts else {
            return false
        }
        let cluster = Int(header.contextMap.map[context])
        return cluster >= 0
            && cluster < ans.aliasTables.count
            && cluster < header.uintConfigs.count
    }

    @inline(__always)
    package func singleContextANSCluster(
        context: Int
    ) -> (AliasTable, HybridUintConfig, UInt32, Bool) {
        let cluster = Int(header.contextMap.map[context])
        let ans = ansDecoder!
        return (
            ans.aliasTables[cluster],
            header.uintConfigs[cluster],
            ans.currentState,
            ans.hasInitialised
        )
    }

    @inline(__always)
    package func singleContextANSFlatCluster(
        context: Int
    ) -> (flatSlots: [UInt64], clusterOffset: Int, config: HybridUintConfig, state: UInt32, initialised: Bool) {
        let cluster = Int(header.contextMap.map[context])
        let ans = ansDecoder!
        return (
            ans.flatSlots,
            cluster &<< ANSConstants.logTabSize,
            header.uintConfigs[cluster],
            ans.currentState,
            ans.hasInitialised
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
              ansInitError == nil,
              let ans = ansDecoder else {
            return false
        }
        return ans.useAliasTables
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
        let ans = ansDecoder!
        return (
            ans.flatSlots,
            header.contextMap.map,
            header.uintConfigs,
            header.contextMap.numContexts,
            header.uintConfigs.count,
            ans.currentState,
            ans.hasInitialised
        )
    }

    @inline(__always)
    package mutating func updateSingleContextANSState(
        _ state: UInt32,
        initialised: Bool
    ) {
        ansDecoder?.updateState(state, initialised: initialised)
    }

    @inline(__always)
    private mutating func readRawSymbol(
        cluster: Int,
        from r: inout BitReader
    ) throws -> UInt32 {
        if header.usePrefixCode {
            guard cluster >= 0 && cluster < codebook.huffmanTables.count else {
                throw TokenStreamReaderError.clusterOutOfRange(
                    cluster,
                    max: codebook.huffmanTables.count - 1
                )
            }
            do {
                let sym = try codebook.huffmanTables[cluster].decode(from: &r)
                return UInt32(sym)
            } catch let error as PrefixCodeError {
                throw TokenStreamReaderError.prefix(error)
            }
        } else {
            if let err = ansInitError {
                throw TokenStreamReaderError.alias(err)
            }
            guard var ans = ansDecoder,
                  cluster >= 0 && cluster < ans.aliasTables.count else {
                throw TokenStreamReaderError.clusterOutOfRange(
                    cluster,
                    max: (ansDecoder?.aliasTables.count ?? 0) - 1
                )
            }
            do {
                let sym = try ans.readSymbol(cluster: cluster, from: &r)
                self.ansDecoder = ans
                return sym
            } catch let error as ANSError {
                throw TokenStreamReaderError.ans(error)
            } catch let error as BitstreamError {
                throw TokenStreamReaderError.bitstream(error)
            }
        }
    }

    @inline(__always)
    private func expandHybridUint(
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

        guard context >= 0 && context < header.contextMap.numContexts else {
            throw TokenStreamReaderError.contextOutOfRange(
                context,
                max: header.contextMap.numContexts - 1
            )
        }
        let cluster = Int(header.contextMap.map[context])
        guard cluster >= 0 && cluster < header.uintConfigs.count else {
            throw TokenStreamReaderError.clusterOutOfRange(
                cluster,
                max: header.uintConfigs.count - 1
            )
        }

        let token = try readRawSymbol(cluster: cluster, from: &r)

        if !header.lz77.enabled || token < header.lz77.minSymbol {
            let value = try expandHybridUint(
                config: header.uintConfigs[cluster],
                token: token,
                from: &r
            )
            if header.lz77.enabled {
                lz77Window[lz77NumDecoded & Self.lz77WindowMask] = value
                lz77NumDecoded &+= 1
            }
            return value
        }

        // ISO/IEC 18181-1 Clause 7.4: LZ77 length-and-distance pair.
        let lengthToken = token &- header.lz77.minSymbol
        let baseLength = try expandHybridUint(
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
        let rawDistance = try expandHybridUint(
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
            guard let ans = ansDecoder,
                  ans.hasInitialised,
                  ans.currentState == ANSConstants.initialState else {
                throw TokenStreamReaderError.ansFinalStateMismatch(
                    got: ansDecoder?.currentState ?? 0
                )
            }
        }
    }

    /// Consume the 32-bit initial rANS state if no symbols were decoded in an
    /// ANS section, then verify the terminal rANS checksum (`0x130000`).
    package mutating func finish(from r: inout BitReader) throws {
        if !header.usePrefixCode, let ans = ansDecoder, !ans.hasInitialised {
            do {
                let state = try r.read(bits: 32)
                ansDecoder?.updateState(state, initialised: true)
            } catch let error as BitstreamError {
                throw TokenStreamReaderError.bitstream(error)
            }
        }
        try finish()
    }
}
