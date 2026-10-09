// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Codec/JXLDecoder.swift, decodeModular, at
// 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// Section/channel ordering checked against libjxl v0.12.0 dec_modular.cc.
// JPEG XL Project Authors' algorithms retain BSD-3-Clause terms;
// see Documentation/ThirdParty/libjxl-LICENSE.txt.
import Foundation

/// Internal integer Modular preparation. Public storage/capability integration
/// is separate. ICC, animation, subsampled extras and display conversion are
/// explicit rejections, never silently discarded or transformed.
package struct ModularDecodedFrame {
    package let width: Int, height: Int, bitsPerSample: Int
    package let grayscale: Bool
    package let alphaAssociated: Bool?
    package let renderingIntent: RenderingIntent
    package let image: ModularImage
}

package enum ModularFrameDecoder {
    private typealias Entropy = (ModularTree, EntropySectionHeader, MultiClusterCodebook)
    private struct Rect {
        let channel: Int, x: Int, y: Int, width: Int, height: Int
    }

    package static func decode(_ data: Data, budget: ScalarOperationBudget,
                               maximumDimension: Int = 16384, maximumPixels: Int = 64 * 1024 * 1024) throws -> ModularDecodedFrame {
        try budget.checkpoint()
        guard data.count <= budget.maximumCompressedBytes else { throw ScalarModularError.resourceLimit }
        // Container extraction, BitReader byte copies, and aggregate section
        // copies are all bounded by the admitted compressed input length.
        try budget.reserveWorkspace(ScalarOperationBudget.sum(ScalarOperationBudget.product(data.count, 6),
            ScalarOperationBudget.sum(256 * min(4096, data.count / 8), 64 * 1024)))
        let codestream: Data
        switch try parseJXLContainer(data, checkpoint: budget.checkpoint) {
        case .naked: codestream = data
        case .iso(let boxes):
            guard boxes.allSatisfy({ ["ftyp", "jxll", "jxlc", "jxlp"].contains($0.type) }) else {
                throw ScalarModularError.unsupportedProfile
            }
            codestream = try extractCodestream(from: boxes, in: data, checkpoint: budget.checkpoint)
        }
        guard hasCodestreamSignature(codestream) else { throw ScalarModularError.invalidInput("Missing codestream signature") }
        var reader = makeReader(codestream, budget: budget, startingAt: 16)
        let size = try SizeHeader.read(from: &reader)
        let width = Int(size.xsize), height = Int(size.ysize)
        let pixels = try ScalarOperationBudget.product(width, height)
        guard width > 0, height > 0, width <= min(maximumDimension, 16384),
              height <= min(maximumDimension, 16384), pixels <= maximumPixels else {
            throw ScalarModularError.resourceLimit
        }
        let metadata = try ImageMetadata.read(from: &reader)
        let gray = metadata.colorEncoding.colorSpace == .grayscale
        guard !metadata.bitDepth.floatingPoint, (8...16).contains(metadata.bitDepth.bitsPerSample),
              !metadata.xybEncoded, gray || metadata.colorEncoding.colorSpace == .rgb,
              !metadata.colorEncoding.useICC, metadata.orientation == 1,
              metadata.preview == nil, metadata.animation == nil, metadata.intrinsicSize == nil,
              metadata.colorEncoding.whitePoint == .d65, metadata.colorEncoding.transferFunction == .srgb,
              gray || metadata.colorEncoding.primaries == .srgb,
              metadata.intensityTarget == 255, metadata.minNits == 0,
              !metadata.relativeToMaxDisplay, metadata.linearBelow == 0,
              metadata.extraChannels.count <= 1 else { throw ScalarModularError.unsupportedProfile }
        for extra in metadata.extraChannels {
            guard extra.type == .alpha, !extra.bitDepth.floatingPoint,
                  extra.bitDepth.bitsPerSample == metadata.bitDepth.bitsPerSample,
                  extra.dimShift == 0, extra.name.isEmpty else { throw ScalarModularError.unsupportedProfile }
        }
        let channels = (gray ? 1 : 3) + metadata.extraChannels.count
        try budget.reservePixels(ScalarOperationBudget.product(ScalarOperationBudget.product(pixels, channels), 2))
        guard try reader.readBit() else { throw ScalarModularError.unsupportedProfile }
        try reader.expectZeroPadding()
        let frame = try FrameHeader.read(from: &reader, context: .init(xybEncoded: false,
            numExtraChannels: metadata.extraChannels.count))
        guard frame.encoding == .modular, frame.frameType == .regular, frame.isLast,
              frame.flags == 0, frame.colorTransform == .none, frame.upsampling == 1,
              frame.extraChannelUpsampling.allSatisfy({ $0 == 1 }),
              !frame.customSizeOrOrigin,
              frame.blendingInfo.mode == .replace, frame.extraChannelBlendingInfo.allSatisfy({ $0.mode == .replace }),
              frame.name.isEmpty, !frame.loopFilter.gab, frame.loopFilter.epfIters == 0 else {
            throw ScalarModularError.unsupportedProfile
        }
        let groupDimension = 128 << Int(frame.groupSizeShift)
        let groupsX = (width - 1) / groupDimension + 1, groupsY = (height - 1) / groupDimension + 1
        let groupCount = try ScalarOperationBudget.product(groupsX, groupsY)
        let dcDimension = groupDimension * 8
        let dcX = (width - 1) / dcDimension + 1, dcY = (height - 1) / dcDimension + 1
        let dcCount = try ScalarOperationBudget.product(dcX, dcY)
        let passes = Int(frame.passes.numPasses)
        let brackets = try downsamplingBrackets(frame.passes)
        let multipleSections = groupCount != 1 || passes != 1
        let entries = TOC.numEntries(numGroups: groupCount, numDcGroups: dcCount, numPasses: passes)
        try budget.reserveWorkspace(try ScalarOperationBudget.product(entries, 128))
        let toc = try TOC.read(from: &reader, numEntries: entries)
        let start = reader.position / 8
        var total = 0
        for size in toc.entrySizes { total = try ScalarOperationBudget.sum(total, Int(size)) }
        guard total == codestream.count - start else { throw ScalarModularError.invalidInput("Invalid section lengths") }
        func section(_ index: Int) throws -> BitReader {
            try budget.checkpoint()
            guard let offset = Int(exactly: toc.offsets[index]), offset <= total,
                  Int(toc.entrySizes[index]) <= total - offset else {
                throw ScalarModularError.invalidInput("Invalid section offset")
            }
            let lower = start + offset, upper = lower + Int(toc.entrySizes[index])
            return makeReader(codestream.subdata(in: lower..<upper), budget: budget)
        }
        var globalReader = try section(0)
        guard try globalReader.readBit() else { throw ScalarModularError.unsupportedProfile }
        let global: Entropy? = try globalReader.readBit()
            ? ScalarModularDecoder.readTreeAndCodebook(from: &globalReader, pixelCount: pixels) : nil
        let header = try GroupHeader.read(from: &globalReader)
        let selected = try entropy(header, global: global, reader: &globalReader, samples: pixels)
        try ModularImage.admitDescriptors(channels, budget: budget)
        var image = try ModularImage(channels: (0..<channels).map { _ in
            try ModularChannel(width: width, height: height)
        })
        let transforms = try metaApplyTransforms(image: &image, transforms: header.transforms, budget: budget)
        let originalCount = image.channels.count
        try budget.reserveWorkspace(originalCount * MemoryLayout<Int>.stride + 128)
        var written = [Int](repeating: 0, count: originalCount)
        var globalEnd = image.nbMetaChannels
        while globalEnd < originalCount {
            let channel = image.channels[globalEnd]
            if multipleSections && (channel.width > groupDimension || channel.height > groupDimension) { break }
            globalEnd += 1
        }
        // Allocate each admitted algorithm plane once. Group rectangles are
        // independent scratch; all output remains unpublished on any failure.
        for c in image.channels.indices { try image.channels[c].allocatePixels(budget: budget) }
        try decodeChannels(image: &image, count: globalEnd, reader: &globalReader, selected: selected,
                           predictor: header.wpHeader, groupID: 0, budget: budget)
        for c in 0..<globalEnd { written[c] = image.channels[c].sampleCount }
        try finishSection(&globalReader, context: "global")
        if multipleSections {
            // No AC-global payload exists for this integer Modular profile.
            guard toc.entrySizes[1 + dcCount] == 0 else { throw ScalarModularError.unsupportedProfile }
            for dc in 0..<dcCount {
                var r = try section(1 + dc)
                try decodeGroup(image: &image, written: &written, first: globalEnd,
                    x: (dc % dcX) * dcDimension, y: (dc / dcX) * dcDimension,
                    quantum: dcDimension, minShift: 3, maxShift: 31, groupID: Int32(1 + dc),
                    reader: &r, global: global, bitDepth: Int(metadata.bitDepth.bitsPerSample), budget: budget)
            }
            for pass in 0..<passes {
                for group in 0..<groupCount {
                    var r = try section(2 + dcCount + pass * groupCount + group)
                    try decodeGroup(image: &image, written: &written, first: globalEnd,
                        x: (group % groupsX) * groupDimension, y: (group / groupsX) * groupDimension,
                        quantum: groupDimension, minShift: brackets[pass].0, maxShift: brackets[pass].1,
                        groupID: Int32(1 + dcCount + pass * groupCount + group),
                        reader: &r, global: global, bitDepth: Int(metadata.bitDepth.bitsPerSample), budget: budget)
                }
            }
        }
        guard image.channels.indices.allSatisfy({ written[$0] == image.channels[$0].sampleCount }) else {
            throw ScalarModularError.invalidInput("Incomplete group coverage")
        }
        try applyInverseTransforms(image: &image, transforms: transforms,
                                   bitDepth: Int(metadata.bitDepth.bitsPerSample), budget: budget)
        guard image.nbMetaChannels == 0, image.channels.count == channels else {
            throw ScalarModularError.invalidInput("Invalid restored channel count")
        }
        let maximum = (Int32(1) << metadata.bitDepth.bitsPerSample) - 1
        for channel in image.channels {
            guard channel.width == width, channel.height == height, channel.hshift == 0, channel.vshift == 0 else {
                throw ScalarModularError.invalidInput("Invalid restored channel geometry")
            }
            for i in channel.pixels.indices {
                if i & 1023 == 0 { try budget.checkpoint() }
                guard channel.pixels[i] >= 0, channel.pixels[i] <= maximum else {
                    throw ScalarModularError.invalidInput("Sample outside declared precision")
                }
            }
        }
        return ModularDecodedFrame(width: width, height: height, bitsPerSample: Int(metadata.bitDepth.bitsPerSample),
            grayscale: gray, alphaAssociated: metadata.extraChannels.first?.alphaAssociated,
            renderingIntent: metadata.colorEncoding.renderingIntent, image: image)
    }

    /// Modular pass brackets use downsample/lastPass, not the VarDCT
    /// coefficient shifts. Mirrors libjxl Passes::GetDownsamplingBracket.
    private static func downsamplingBrackets(_ passes: Passes) throws -> [(Int, Int)] {
        guard (1...11).contains(passes.numPasses),
              passes.downsamples.count == Int(passes.numDownsample),
              passes.lastPasses.count == passes.downsamples.count,
              passes.lastPasses.allSatisfy({ $0 < passes.numPasses }) else {
            throw ScalarModularError.invalidInput("Invalid pass configuration")
        }
        var result: [(Int, Int)] = [], minimum = 3, maximum = 2
        for pass in 0..<Int(passes.numPasses) {
            for level in passes.lastPasses.indices where Int(passes.lastPasses[level]) == pass {
                guard [UInt32(1), 2, 4, 8].contains(passes.downsamples[level]) else {
                    throw ScalarModularError.invalidInput("Invalid downsampling factor")
                }
                minimum = passes.downsamples[level].trailingZeroBitCount
            }
            if pass == Int(passes.numPasses) - 1 { minimum = 0 }
            guard minimum <= maximum + 1 else { throw ScalarModularError.invalidInput("Overlapping pass brackets") }
            result.append((minimum, maximum))
            maximum = minimum - 1
        }
        return result
    }

    private static func makeReader(_ data: Data, budget: ScalarOperationBudget, startingAt: Int = 0) -> BitReader {
        BitReader(data, startingAt: startingAt, deadline: budget.deadline,
                  maximumEntropyTableBytes: 32 * 1024 * 1024, budget: budget)
    }
    private static func entropy(_ header: GroupHeader, global: Entropy?, reader: inout BitReader,
                                samples: Int) throws -> Entropy {
        if header.useGlobalTree {
            guard let global else { throw ScalarModularError.invalidInput("Global tree is absent") }
            return global
        }
        return try ScalarModularDecoder.readTreeAndCodebook(from: &reader, pixelCount: samples)
    }
    private static func finishSection(_ reader: inout BitReader, context: String = "group") throws {
        try reader.expectZeroPadding()
        guard reader.isExhausted else { throw ScalarModularError.invalidInput("Trailing \(context) section bytes: \(reader.bitsRemaining / 8)") }
    }
    private static func decodeChannels(image: inout ModularImage, count: Int, reader: inout BitReader,
                                       selected: Entropy, predictor: WeightedPredictorHeader,
                                       groupID: Int32, budget: ScalarOperationBudget) throws {
        var distance = 0, samples = 0
        for c in 0..<count where image.channels[c].sampleCount > 0 {
            distance = max(distance, image.channels[c].width)
            samples = try ScalarOperationBudget.sum(samples, image.channels[c].sampleCount)
        }
        // LZ77 history growth/capacity, independent of final algorithm planes.
        try budget.reserveWorkspace(ScalarOperationBudget.product(samples, 12))
        if samples == 0 {
            // libjxl constructs/finalises its entropy reader even when all
            // channels defer to groups. An empty rANS stream still carries
            // its initial/final 32-bit state; prefix streams carry no state.
            if !selected.1.usePrefixCode {
                guard try reader.read(bits: 32) == ANSConstants.initialState else {
                    throw ScalarModularError.invalidInput("Invalid empty entropy state")
                }
            }
            return
        }
        if !selected.1.usePrefixCode {
            try budget.reserveWorkspace(ScalarOperationBudget.product(selected.2.ansCounts.count, 64 * 1024))
        }
        var stream = TokenStreamReader(header: selected.1, codebook: selected.2, distanceMultiplier: distance)
        for c in 0..<count where image.channels[c].sampleCount > 0 {
            let width = image.channels[c].width, height = image.channels[c].height
            try budget.reserveWorkspace(ScalarOperationBudget.sum(192 * (width + 2), 1024))
            var plane: [Int32] = []
            swap(&plane, &image.channels[c].pixels)
            try decodeModularChannel(width: width, height: height, staticChannel: Int32(c), groupId: groupID,
                tree: selected.0, stream: &stream, from: &reader, wpHeader: predictor, out: &plane)
            image.channels[c].pixels = plane
        }
        if samples > 0 { try stream.finish() }
    }
    private static func decodeGroup(image: inout ModularImage, written: inout [Int], first: Int,
                                    x: Int, y: Int, quantum: Int, minShift: Int, maxShift: Int, groupID: Int32,
                                    reader: inout BitReader, global: Entropy?, bitDepth: Int,
                                    budget: ScalarOperationBudget) throws {
        try budget.checkpoint()
        try ModularImage.admitDescriptors(image.channels.count - first, budget: budget)
        try budget.reserveWorkspace((image.channels.count - first) * MemoryLayout<Rect>.stride + 128)
        var rectangles: [Rect] = [], geometry: [ModularChannel] = []
        for c in first..<image.channels.count {
            let channel = image.channels[c], shift = min(channel.hshift, channel.vshift)
            guard shift >= minShift, shift <= maxShift else { continue }
            let qx = quantum >> channel.hshift, qy = quantum >> channel.vshift
            guard qx > 0, qy > 0 else { throw ScalarModularError.unsupportedProfile }
            let x0 = x >> channel.hshift, y0 = y >> channel.vshift
            if x0 >= channel.width || y0 >= channel.height { continue }
            let w = min(qx, channel.width - x0), h = min(qy, channel.height - y0)
            geometry.append(try ModularChannel(width: w, height: h, hshift: channel.hshift, vshift: channel.vshift))
            rectangles.append(Rect(channel: c, x: x0, y: y0, width: w, height: h))
        }
        if geometry.isEmpty { try finishSection(&reader); return }
        let header = try GroupHeader.read(from: &reader)
        let selected = try entropy(header, global: global, reader: &reader, samples: quantum * quantum)
        var subimage = try ModularImage(channels: geometry)
        let transforms = try metaApplyTransforms(image: &subimage, transforms: header.transforms, budget: budget)
        for c in subimage.channels.indices { try subimage.channels[c].allocatePixels(budget: budget) }
        try decodeChannels(image: &subimage, count: subimage.channels.count, reader: &reader, selected: selected,
                           predictor: header.wpHeader, groupID: groupID, budget: budget)
        try finishSection(&reader)
        try applyInverseTransforms(image: &subimage, transforms: transforms, bitDepth: bitDepth, budget: budget)
        guard subimage.nbMetaChannels == 0, subimage.channels.count == rectangles.count else {
            throw ScalarModularError.invalidInput("Invalid group channel count")
        }
        for (index, rect) in rectangles.enumerated() {
            let channel = subimage.channels[index]
            guard channel.sameGeometry(as: geometry[index]) else { throw ScalarModularError.invalidInput("Invalid group geometry") }
            let parentWidth = image.channels[rect.channel].width
            // Rectangles are checked/clipped to their parent above. These
            // synchronous borrows never escape and no parallel writes occur.
            try image.channels[rect.channel].pixels.withUnsafeMutableBufferPointer { destination in
                try channel.pixels.withUnsafeBufferPointer { source in
                    for row in 0..<rect.height {
                        try budget.checkpoint()
                        let offset = (rect.y + row) * parentWidth + rect.x
                        for column in 0..<rect.width {
                            if column & 1023 == 0 { try budget.checkpoint() }
                            destination[offset + column] = source[row * rect.width + column]
                        }
                    }
                }
            }
            written[rect.channel] = try ScalarOperationBudget.sum(written[rect.channel], channel.sampleCount)
        }
    }
}
