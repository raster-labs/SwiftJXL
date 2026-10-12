// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Frame traversal adapted from JXLSwift Codec/JXLDecoder.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e; rewritten with bounded admission.
import Foundation

/// Structural index for independent full-canvas frames. This does not decode
/// pixels or promise support by a pixel decoder. Existing still-image parsing
/// remains unchanged. Each range is checked against the retained codestream
/// before publication; callers never construct slices from unchecked TOC sizes.
package struct AnimationFrameIndex: Sendable {
    package struct Entry: Sendable {
        package let header: FrameHeader
        package let frameRange: Range<Int>
        package let payloadRange: Range<Int>
        package let toc: TOC
        package let startTick: UInt64
        package var duration: UInt32 { header.animationFrame.duration }
    }
    package let image: PixelFrameHeader
    package let animation: AnimationHeader?
    package let preludeRange: Range<Int>
    package let frames: [Entry]
    package let totalTicks: UInt64

    /// Scans every frame through the final marker, including for indexed access.
    /// Limits apply to coded frames and the sum of declared durations. Duration
    /// zero, reference-only frames, compositing and timecodes are outside this
    /// first profile. Still images retain their zero duration and single frame.
    package static func read(_ data: Data, budget: ScalarOperationBudget,
                             maximumFrames: Int = 1, maximumTotalTicks: UInt64 = .max,
                             maximumDimension: Int = 16384,
                             maximumPixels: Int = 64 * 1024 * 1024,
                             maximumNestingDepth: Int = 32) throws -> Self {
        guard maximumFrames > 0 else { throw ScalarModularError.resourceLimit }
        let image = try PixelFrameHeader.read(data, budget: budget,
            maximumDimension: maximumDimension, maximumPixels: maximumPixels,
            maximumNestingDepth: maximumNestingDepth)
        let metadata = image.metadata
        guard metadata.preview == nil, metadata.intrinsicSize == nil,
              metadata.orientation == 1, !metadata.colorEncoding.useICC,
              !metadata.bitDepth.floatingPoint,
              (1...16).contains(metadata.bitDepth.bitsPerSample),
              [.rgb, .grayscale].contains(metadata.colorEncoding.colorSpace),
              metadata.extraChannels.count <= 1 else { throw ScalarModularError.unsupportedProfile }
        for extra in metadata.extraChannels {
            guard extra.type == .alpha, !extra.bitDepth.floatingPoint,
                  extra.bitDepth.bitsPerSample == metadata.bitDepth.bitsPerSample,
                  extra.dimShift == 0, extra.name.isEmpty else { throw ScalarModularError.unsupportedProfile }
        }
        let animation = metadata.animation
        if let animation {
            guard animation.tpsNumerator > 0, animation.tpsDenominator > 0 else {
                throw ScalarModularError.invalidInput("Animation tick rate must be positive")
            }
            guard !animation.haveTimecodes else { throw ScalarModularError.unsupportedProfile }
        }
        var reader = image.reader
        guard try reader.readBit() else { throw ScalarModularError.unsupportedProfile } // default transforms
        try reader.expectZeroPadding()
        let preludeEnd = reader.position / 8
        let context = FrameHeaderContext(xybEncoded: metadata.xybEncoded,
            numExtraChannels: metadata.extraChannels.count,
            haveAnimation: animation != nil, haveTimecodes: false)
        var frames: [Entry] = [], totalTicks: UInt64 = 0
        while true {
            try budget.checkpoint()
            guard frames.count < maximumFrames else { throw ScalarModularError.resourceLimit }
            // Includes retained header/name/array and index capacity overhead.
            try budget.reserveWorkspace(4096)
            let begin = reader.position / 8
            let frame = try FrameHeader.read(from: &reader, context: context)
            guard frame.frameType == .regular, !frame.customSizeOrOrigin,
                  frame.blendingInfo.mode == .replace,
                  frame.extraChannelBlendingInfo.allSatisfy({ $0.mode == .replace }),
                  frame.saveAsReference == 0, frame.flags == 0 || frame.flags == 128,
                  frame.upsampling == 1, frame.extraChannelUpsampling.allSatisfy({ $0 == 1 }),
                  frame.name.isEmpty,
                  (metadata.xybEncoded ? frame.colorTransform == .xyb : frame.colorTransform == .none) else {
                throw ScalarModularError.unsupportedProfile
            }
            guard animation != nil || (frames.isEmpty && frame.isLast) else {
                throw ScalarModularError.unsupportedProfile
            }
            guard animation == nil || frame.animationFrame.duration > 0 else {
                throw ScalarModularError.unsupportedProfile
            }
            let (nextTicks, overflow) = totalTicks.addingReportingOverflow(UInt64(frame.animationFrame.duration))
            guard !overflow, nextTicks <= maximumTotalTicks else { throw ScalarModularError.resourceLimit }
            // Header parser bounds groupSizeShift and pass count. Checked products
            // here prevent future profile expansion from weakening admission.
            guard frame.groupSizeShift <= 3, frame.passes.numPasses > 0,
                  frame.passes.numPasses <= 11 else { throw ScalarModularError.unsupportedProfile }
            let dimension = 128 << Int(frame.groupSizeShift)
            let groups = try ScalarOperationBudget.product((image.width - 1) / dimension + 1,
                                                          (image.height - 1) / dimension + 1)
            let dcGroups = try ScalarOperationBudget.product((image.width - 1) / (dimension * 8) + 1,
                                                            (image.height - 1) / (dimension * 8) + 1)
            let entries = groups == 1 && frame.passes.numPasses == 1 ? 1 :
                try ScalarOperationBudget.sum(2 + dcGroups,
                    ScalarOperationBudget.product(groups, Int(frame.passes.numPasses)))
            try budget.reserveWorkspace(ScalarOperationBudget.product(entries, 128))
            let toc = try TOC.read(from: &reader, numEntries: entries)
            let start = reader.position / 8
            var length = 0
            for size in toc.entrySizes { length = try ScalarOperationBudget.sum(length, Int(size)) }
            guard start <= image.codestream.count, length <= image.codestream.count - start else {
                throw ScalarModularError.invalidInput("Animation frame extends past codestream end")
            }
            for i in toc.entrySizes.indices {
                guard let offset = Int(exactly: toc.offsets[i]), offset <= length,
                      Int(toc.entrySizes[i]) <= length - offset else {
                    throw ScalarModularError.invalidInput("Invalid animation section offset")
                }
            }
            let end = start + length
            frames.append(Entry(header: frame, frameRange: begin..<end,
                payloadRange: start..<end, toc: toc, startTick: totalTicks))
            totalTicks = nextTicks
            try reader.skip(bits: ScalarOperationBudget.product(length, 8))
            if frame.isLast {
                guard end == image.codestream.count else {
                    throw ScalarModularError.invalidInput("Trailing bytes after final animation frame")
                }
                break
            }
        }
        return Self(image: image, animation: animation, preludeRange: 0..<preludeEnd,
                    frames: frames, totalTicks: totalTicks)
    }

    package func frame(at index: Int) throws -> Entry {
        try image.budget.checkpoint()
        guard frames.indices.contains(index) else { throw ScalarModularError.invalidInput("Frame index out of range") }
        return frames[index]
    }
}
