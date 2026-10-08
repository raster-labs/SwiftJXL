// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Single-section flow adapted from JXLSwift 57e81cb9e2411d1efac435b429a306a031744c1e,
// Sources/JXLSwift/Codec/JXLDecoder.swift, decodeModular (lines 4320–4562).
import Foundation

/// Internal migration profile. Public admission/storage integration is qualified separately.
package enum ScalarModularError: Error {
    case unsupportedProfile
    case invalidInput(String)
    case resourceLimit
}

package struct ScalarModularImage {
    package let width: Int
    package let height: Int
    package let bitsPerSample: Int
    package let pixels: [Int32]
}

package enum ScalarModularDecoder {
    package static func decode(_ data: Data) throws -> ScalarModularImage {
        let frame = try prepare(data)
        var pixels = [Int32](repeating: 0, count: frame.width * frame.height)
        try frame.decode(into: &pixels)
        return ScalarModularImage(width: frame.width, height: frame.height,
                                  bitsPerSample: frame.bitsPerSample, pixels: pixels)
    }

    /// First qualified profile: naked, single-group, single-frame unsigned greyscale,
    /// 8–16 bits, no colour transform, extra channels, palette, squeeze or metadata.
    package static func prepare(_ data: Data) throws -> ScalarModularFrame {
        try Task.checkCancellation()
        guard data.count <= 4 * 1024 * 1024 else { throw ScalarModularError.resourceLimit }
        let codestream: Data
        switch try parseJXLContainer(data) {
        case .naked: codestream = data
        case .iso(let boxes):
            guard boxes.allSatisfy({ ["ftyp", "jxll", "jxlc", "jxlp"].contains($0.type) }) else {
                throw ScalarModularError.unsupportedProfile
            }
            codestream = try extractCodestream(from: boxes, in: data)
        }
        guard hasCodestreamSignature(codestream) else { throw ScalarModularError.invalidInput("Missing JPEG XL codestream signature") }
        var r = BitReader(codestream, startingAt: 16)
        let size = try SizeHeader.read(from: &r)
        let width = Int(size.xsize), height = Int(size.ysize)
        guard width > 0, height > 0, width <= 1024, height <= 1024 else {
            throw ScalarModularError.resourceLimit
        }
        let m = try ImageMetadata.read(from: &r)
        guard !m.bitDepth.floatingPoint, (8...16).contains(m.bitDepth.bitsPerSample),
              !m.xybEncoded, m.colorEncoding.colorSpace == .grayscale,
              !m.colorEncoding.useICC, m.extraChannels.isEmpty,
              m.orientation == 1, m.preview == nil, m.animation == nil,
              m.intrinsicSize == nil else { throw ScalarModularError.unsupportedProfile }
        // CustomTransformData: only its all-default branch is in this profile.
        guard try r.readBit() else { throw ScalarModularError.unsupportedProfile }
        try r.expectZeroPadding()
        let fh = try FrameHeader.read(from: &r, context: .init(xybEncoded: false))
        let groupDimension = 128 << Int(fh.groupSizeShift)
        guard fh.encoding == .modular, fh.frameType == .regular, fh.isLast,
              fh.flags == 0, fh.colorTransform == .none, fh.upsampling == 1,
              fh.passes.numPasses == 1, !fh.customSizeOrOrigin,
              fh.blendingInfo.mode == .replace, fh.name.isEmpty,
              width <= groupDimension, height <= groupDimension,
              !fh.loopFilter.gab, fh.loopFilter.epfIters == 0 else {
            throw ScalarModularError.unsupportedProfile
        }
        let toc = try TOC.read(from: &r, numEntries: 1)
        guard toc.entrySizes.count == 1,
              Int(toc.entrySizes[0]) == r.bitsRemaining / 8 else {
            throw ScalarModularError.invalidInput("Section length does not match input")
        }
        // Modular frames do not use custom VarDCT DC matrices.
        guard try r.readBit() else { throw ScalarModularError.unsupportedProfile }
        let hasGlobalTree = try r.readBit()
        var global: (ModularTree, EntropySectionHeader, MultiClusterCodebook)?
        if hasGlobalTree { global = try readTreeAndCodebook(from: &r, pixelCount: width * height) }
        let gh = try GroupHeader.read(from: &r)
        guard gh.transforms.isEmpty else { throw ScalarModularError.unsupportedProfile }
        let selected: (ModularTree, EntropySectionHeader, MultiClusterCodebook)
        if gh.useGlobalTree {
            guard let global else { throw ScalarModularError.invalidInput("Global tree is absent") }
            selected = global
        } else {
            selected = try readTreeAndCodebook(from: &r, pixelCount: width * height)
        }
        return ScalarModularFrame(width: width, height: height,
            bitsPerSample: Int(m.bitDepth.bitsPerSample), reader: r,
            tree: selected.0, header: selected.1, codebook: selected.2, predictor: gh.wpHeader)
    }

    private static func readTreeAndCodebook(from r: inout BitReader, pixelCount: Int)
        throws -> (ModularTree, EntropySectionHeader, MultiClusterCodebook) {
        let header = try EntropySectionHeader.read(from: &r, numContexts: 6)
        let codebook = try MultiClusterCodebook.read(from: &r, header: header)
        var stream = TokenStreamReader(header: header, codebook: codebook)
        let tree = try ModularTree.decode(from: &r, stream: &stream,
                                         treeSizeLimit: min(4096, 1024 + pixelCount / 16))
        try stream.finish()
        let post = try EntropySectionHeader.read(from: &r, numContexts: tree.leafCount)
        let postCodebook = try MultiClusterCodebook.read(from: &r, header: post)
        return (tree, post, postCodebook)
    }
}

/// Parsed scalar frame. Pixel allocation is the caller's responsibility.
package struct ScalarModularFrame: Sendable {
    package let width: Int
    package let height: Int
    package let bitsPerSample: Int
    let reader: BitReader
    let tree: ModularTree
    let header: EntropySectionHeader
    let codebook: MultiClusterCodebook
    let predictor: WeightedPredictorHeader

    package func decode<Storage: ModularSampleBuffer>(into destination: inout Storage) throws {
        try Task.checkCancellation()
        var r = reader
        var stream = TokenStreamReader(header: header, codebook: codebook, distanceMultiplier: width)
        try decodeModularChannel(width: width, height: height,
            staticChannel: 0, groupId: 0, tree: tree, stream: &stream,
            from: &r, wpHeader: predictor,
            sampleMaximum: (Int32(1) << bitsPerSample) - 1, out: &destination)
        try stream.finish()
        try r.expectZeroPadding()
        guard r.isExhausted else { throw ScalarModularError.invalidInput("Unexpected trailing section bytes") }
        try Task.checkCancellation()
    }
}
