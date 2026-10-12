// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Codec/JXLDecoder.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// ISO/IEC 18181-1 §C.8. JPEG XL Project Authors retain BSD-3-Clause terms.
// See Documentation/ThirdParty/libjxl-LICENSE.txt.
import Foundation

/// Immutable, bounded frame preparation. This recognises the single-frame XYB
/// envelope; it does not assert support for its coefficients or publish pixels.
package struct VarDCTFrameEnvelope: Sendable {
    package let width: Int, height: Int
    package let metadata: ImageMetadata
    /// Preserved interpretation metadata. Internal XYB reconstruction does not
    /// apply this profile; output conversion must be explicitly qualified.
    package let iccProfile: Data?
    package let frame: FrameHeader
    package let groupsX: Int, groupsY: Int, dcGroupsX: Int, dcGroupsY: Int
    package let groupDimension: Int
    package let budget: ScalarOperationBudget
    private let codestream: Data
    private let toc: TOC
    private let start: Int
    private let maximumNestingDepth: Int
    package var sectionCount: Int { toc.entrySizes.count }

    package static func read(_ input: Data, budget: ScalarOperationBudget,
                             maximumDimension: Int = 16384,
                             maximumPixels: Int = 64 * 1024 * 1024,
                             maximumNestingDepth: Int = 32,
                             maximumICCBytes: Int = 4 * 1024 * 1024,
                             maximumMetadataBytes: Int = 16 * 1024 * 1024) throws -> Self {
        let header = try PixelFrameHeader.read(input, budget: budget,
            maximumDimension: maximumDimension, maximumPixels: maximumPixels,
            maximumNestingDepth: maximumNestingDepth)
        return try read(header, maximumICCBytes: maximumICCBytes, maximumMetadataBytes: maximumMetadataBytes)
    }

    package static func read(_ preparedHeader: PixelFrameHeader,
                             maximumICCBytes: Int = 4 * 1024 * 1024,
                             maximumMetadataBytes: Int = 16 * 1024 * 1024) throws -> Self {
        let budget = preparedHeader.budget
        try budget.checkpoint()
        let codestream = preparedHeader.codestream, metadata = preparedHeader.metadata
        let width = preparedHeader.width, height = preparedHeader.height
        let maximumNestingDepth = preparedHeader.maximumNestingDepth
        var reader = preparedHeader.reader
        let colour = metadata.colorEncoding
        guard metadata.xybEncoded, !metadata.bitDepth.floatingPoint,
              (1...16).contains(metadata.bitDepth.bitsPerSample),
              [.rgb, .grayscale].contains(colour.colorSpace),
              colour.useICC || (colour.whitePoint == .d65 && colour.transferFunction == .srgb &&
                  (colour.colorSpace == .grayscale || colour.primaries == .srgb)),
              metadata.orientation == 1, metadata.preview == nil, metadata.animation == nil,
              metadata.intrinsicSize == nil, metadata.intensityTarget == 255, metadata.minNits == 0,
              !metadata.relativeToMaxDisplay, metadata.linearBelow == 0,
              metadata.extraChannels.count <= 1 else { throw ScalarModularError.unsupportedProfile }
        for extra in metadata.extraChannels {
            guard extra.type == .alpha, !extra.bitDepth.floatingPoint,
                  extra.bitDepth.bitsPerSample == metadata.bitDepth.bitsPerSample,
                  extra.dimShift == 0, extra.name.isEmpty else { throw ScalarModularError.unsupportedProfile }
        }
        guard try reader.readBit() else { throw ScalarModularError.unsupportedProfile } // default custom transforms
        let iccProfile: Data?
        if colour.useICC {
            guard maximumICCBytes > 0, maximumMetadataBytes > 0 else { throw ScalarModularError.resourceLimit }
            do {
                iccProfile = try ICCStream.decode(from: &reader,
                    maximumBytes: min(maximumICCBytes, maximumMetadataBytes, 4 * 1024 * 1024),
                    checkpoint: budget.checkpoint)
            } catch JPEGEntropyError.resourceLimit { throw ScalarModularError.resourceLimit }
            if let profile = iccProfile {
                guard profile.count >= 128,
                      profile.prefix(4).reduce(0, { ($0 << 8) | Int($1) }) == profile.count,
                      profile[36..<40] == Data("acsp".utf8),
                      profile[16..<20] == Data((colour.colorSpace == .grayscale ? "GRAY" : "RGB ").utf8) else {
                    throw ScalarModularError.invalidInput("ICC header does not match the image colour model")
                }
            }
        } else { iccProfile = nil }
        try reader.expectZeroPadding()
        let frame = try FrameHeader.read(from: &reader, context: .init(xybEncoded: true,
            numExtraChannels: metadata.extraChannels.count))
        guard frame.encoding == .varDCT, frame.frameType == .regular, frame.isLast,
              frame.flags == 0 || frame.flags == 128, frame.colorTransform == .xyb,
              frame.upsampling == 1, frame.extraChannelUpsampling.allSatisfy({ $0 == 1 }),
              !frame.customSizeOrOrigin, frame.blendingInfo.mode == .replace,
              frame.extraChannelBlendingInfo.allSatisfy({ $0.mode == .replace }), frame.name.isEmpty else {
            throw ScalarModularError.unsupportedProfile
        }
        let dimension = 128 << Int(frame.groupSizeShift)
        let gx = (width - 1) / dimension + 1, gy = (height - 1) / dimension + 1
        let dx = (width - 1) / (dimension * 8) + 1, dy = (height - 1) / (dimension * 8) + 1
        let entries = TOC.numEntries(numGroups: gx * gy, numDcGroups: dx * dy, numPasses: Int(frame.passes.numPasses))
        try budget.reserveWorkspace(ScalarOperationBudget.product(entries, 128))
        let toc = try TOC.read(from: &reader, numEntries: entries)
        let start = reader.position / 8
        var total = 0
        for size in toc.entrySizes { total = try ScalarOperationBudget.sum(total, Int(size)) }
        guard total == codestream.count - start else { throw ScalarModularError.invalidInput("Invalid VarDCT section lengths") }
        for i in toc.entrySizes.indices {
            guard let offset = Int(exactly: toc.offsets[i]), offset <= total,
                  Int(toc.entrySizes[i]) <= total - offset else {
                throw ScalarModularError.invalidInput("Invalid VarDCT section offset")
            }
        }
        return Self(width: width, height: height, metadata: metadata, iccProfile: iccProfile, frame: frame,
            groupsX: gx, groupsY: gy, dcGroupsX: dx, dcGroupsY: dy, groupDimension: dimension,
            budget: budget, codestream: codestream, toc: toc, start: start, maximumNestingDepth: maximumNestingDepth)
    }

    package func section(_ index: Int) throws -> BitReader {
        try budget.checkpoint()
        guard toc.entrySizes.indices.contains(index), let offset = Int(exactly: toc.offsets[index]) else {
            throw ScalarModularError.invalidInput("Invalid VarDCT section index")
        }
        let length = Int(toc.entrySizes[index])
        try budget.reserveWorkspace(ScalarOperationBudget.product(length, 2))
        let bytes = codestream.subdata(in: (start + offset)..<(start + offset + length))
        return BitReader(bytes, deadline: budget.deadline, maximumNestingDepth: maximumNestingDepth, budget: budget)
    }
}
