// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Codec/JXLDecoder.swift, decodeModular, at
// 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// Section/channel ordering checked against libjxl v0.12.0 dec_modular.cc.
// JPEG XL Project Authors' algorithms retain BSD-3-Clause terms;
// see Documentation/ThirdParty/libjxl-LICENSE.txt.
import Foundation

/// Internal integer Modular preparation. Public storage/capability integration
/// is separate. Animation, subsampled extras and display conversion are
/// explicit rejections, never silently discarded or transformed.
package struct ModularDecodedFrame: Sendable {
    package let width: Int, height: Int, bitsPerSample: Int
    package let grayscale: Bool
    package let alphaAssociated: Bool?
    package let renderingIntent: RenderingIntent
    package let transferFunction: TransferFunction
    package let iccProfile: Data?
    package let image: ModularImage
}

package enum ModularFrameDecoder {
    fileprivate typealias Entropy = (ModularTree, EntropySectionHeader, MultiClusterCodebook)
    private struct Rect: Sendable {
        let channel: Int, x: Int, y: Int, width: Int, height: Int
    }

    private struct GroupResult: Sendable {
        let image: ModularImage
        let rectangles: [Rect]
        let wroteDirectly: Bool
    }

    /// Immutable preparation contains compressed input, colour metadata and geometry.
    /// No pointer or decoded sample allocation survives in this Sendable value.
    package struct Prepared: Sendable {
        package let width: Int, height: Int, bitsPerSample: Int
        package let grayscale: Bool
        package let alphaAssociated: Bool?
        package let renderingIntent: RenderingIntent
        package let transferFunction: TransferFunction
        package let iccProfile: Data?
        fileprivate let codestream: Data, toc: TOC, start: Int
        fileprivate let budget: ScalarOperationBudget, maximumNestingDepth: Int
        fileprivate let globalReader: BitReader, global: Entropy?, selected: Entropy
        fileprivate let header: GroupHeader, geometry: ModularImage, transforms: [ModularTransform]
        fileprivate let groupDimension: Int, groupsX: Int, groupCount: Int
        fileprivate let dcDimension: Int, dcX: Int, dcCount: Int, passes: Int
        fileprivate let brackets: [(Int, Int)], multipleSections: Bool

        fileprivate func section(_ index: Int) throws -> BitReader {
            try budget.checkpoint()
            let total = codestream.count - start
            guard toc.entrySizes.indices.contains(index), let offset = Int(exactly: toc.offsets[index]),
                  offset <= total, Int(toc.entrySizes[index]) <= total - offset else {
                throw ScalarModularError.invalidInput("Invalid section offset")
            }
            let lower = start + offset, upper = lower + Int(toc.entrySizes[index])
            return makeReader(codestream.subdata(in: lower..<upper), budget: budget,
                              maximumNestingDepth: maximumNestingDepth)
        }
        package func decode() throws -> ModularDecodedFrame { try ModularFrameDecoder.decode(self) }

        /// The caller retains an exclusive synchronous borrow of validated,
        /// non-overlapping component storage until this call returns or throws.
        /// No pointer is retained and no workers outlive the borrow.
        package func decode(into bytes: UnsafeMutableRawBufferPointer, layouts: [ModularChannelLayout]) throws {
            let count = (grayscale ? 1 : 3) + (alphaAssociated == nil ? 0 : 1)
            guard layouts.count == count, layouts.allSatisfy({
                $0.width == width && $0.height == height && $0.storageBits >= bitsPerSample &&
                $0.requiredBytes <= bytes.count
            }) else { throw ScalarModularError.invalidInput("Modular destination does not match frame") }
            try budget.reservePixels(bytes.count)
            _ = try ModularFrameDecoder.decode(self, destination: .init(bytes: bytes, layouts: layouts))
        }
    }

    package static func decode(_ data: Data, budget: ScalarOperationBudget,
                               maximumDimension: Int = 16384, maximumPixels: Int = 64 * 1024 * 1024) throws -> ModularDecodedFrame {
        try prepare(data, budget: budget, maximumDimension: maximumDimension, maximumPixels: maximumPixels).decode()
    }

    package static func prepare(_ data: Data, budget: ScalarOperationBudget,
                                maximumDimension: Int = 16384, maximumPixels: Int = 64 * 1024 * 1024,
                                maximumNestingDepth: Int = 32,
                                maximumICCBytes: Int = 4 * 1024 * 1024,
                                maximumMetadataBytes: Int = 16 * 1024 * 1024) throws -> Prepared {
        let header = try PixelFrameHeader.read(data, budget: budget,
            maximumDimension: maximumDimension, maximumPixels: maximumPixels,
            maximumNestingDepth: maximumNestingDepth)
        return try prepare(header, maximumICCBytes: maximumICCBytes, maximumMetadataBytes: maximumMetadataBytes)
    }

    package static func prepare(_ preparedHeader: PixelFrameHeader,
                                maximumICCBytes: Int = 4 * 1024 * 1024,
                                maximumMetadataBytes: Int = 16 * 1024 * 1024) throws -> Prepared {
        let budget = preparedHeader.budget
        try budget.checkpoint()
        // Preserve the original six-input-length cumulative allowance: three
        // lengths were admitted by shared preparation, three cover sections.
        try budget.reserveWorkspace(ScalarOperationBudget.product(preparedHeader.inputByteCount, 3))
        let codestream = preparedHeader.codestream, metadata = preparedHeader.metadata
        let width = preparedHeader.width, height = preparedHeader.height
        let pixels = try ScalarOperationBudget.product(width, height)
        let maximumNestingDepth = preparedHeader.maximumNestingDepth
        var reader = preparedHeader.reader
        let gray = metadata.colorEncoding.colorSpace == .grayscale
        guard !metadata.bitDepth.floatingPoint, (1...16).contains(metadata.bitDepth.bitsPerSample),
              !metadata.xybEncoded, gray || metadata.colorEncoding.colorSpace == .rgb,
              metadata.orientation == 1,
              metadata.preview == nil, metadata.animation == nil, metadata.intrinsicSize == nil,
              metadata.colorEncoding.useICC || (metadata.colorEncoding.whitePoint == .d65 &&
                  [TransferFunction.srgb, .bt709].contains(metadata.colorEncoding.transferFunction) &&
                  (gray || metadata.colorEncoding.primaries == .srgb)),
              metadata.intensityTarget == 255, metadata.minNits == 0,
              !metadata.relativeToMaxDisplay, metadata.linearBelow == 0,
              metadata.extraChannels.count <= 1 else { throw ScalarModularError.unsupportedProfile }
        for extra in metadata.extraChannels {
            guard extra.type == .alpha, !extra.bitDepth.floatingPoint,
                  extra.bitDepth.bitsPerSample == metadata.bitDepth.bitsPerSample,
                  extra.dimShift == 0, extra.name.isEmpty else { throw ScalarModularError.unsupportedProfile }
        }
        let channels = (gray ? 1 : 3) + metadata.extraChannels.count
        guard try reader.readBit() else { throw ScalarModularError.unsupportedProfile }
        let iccProfile: Data?
        if metadata.colorEncoding.useICC {
            // Enforce both metadata ceilings before profile allocation. ICCStream
            // charges compressed commands, prediction scratch and retained bytes
            // to this same operation budget, including during inspection.
            do {
                iccProfile = try ICCStream.decode(from: &reader,
                    maximumBytes: min(maximumICCBytes, maximumMetadataBytes, 4 * 1024 * 1024),
                    checkpoint: budget.checkpoint)
            } catch JPEGEntropyError.resourceLimit { throw ScalarModularError.resourceLimit }
            if let profile = iccProfile {
                guard profile.count >= 128,
                      profile.prefix(4).reduce(0, { ($0 << 8) | Int($1) }) == profile.count,
                      profile[36..<40] == Data("acsp".utf8),
                      profile[16..<20] == Data((gray ? "GRAY" : "RGB ").utf8) else {
                    throw ScalarModularError.invalidInput("ICC header does not match the image colour model")
                }
            }
        } else { iccProfile = nil }
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
            return makeReader(codestream.subdata(in: lower..<upper), budget: budget, maximumNestingDepth: maximumNestingDepth)
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
        if multipleSections {
            guard toc.entrySizes[1 + dcCount] == 0 else { throw ScalarModularError.unsupportedProfile }
        }
        try budget.checkpoint()
        return Prepared(width: width, height: height, bitsPerSample: Int(metadata.bitDepth.bitsPerSample),
            grayscale: gray, alphaAssociated: metadata.extraChannels.first?.alphaAssociated,
            renderingIntent: metadata.colorEncoding.renderingIntent, transferFunction: metadata.colorEncoding.transferFunction,
            iccProfile: iccProfile, codestream: codestream, toc: toc, start: start,
            budget: budget, maximumNestingDepth: maximumNestingDepth, globalReader: globalReader,
            global: global, selected: selected, header: header, geometry: image, transforms: transforms,
            groupDimension: groupDimension, groupsX: groupsX, groupCount: groupCount,
            dcDimension: dcDimension, dcX: dcX, dcCount: dcCount, passes: passes,
            brackets: brackets, multipleSections: multipleSections)
    }

    private static func decode(_ plan: Prepared, destination: BorrowedModularDestination? = nil) throws -> ModularDecodedFrame {
        let budget = plan.budget, width = plan.width, height = plan.height
        let channels = (plan.grayscale ? 1 : 3) + (plan.alphaAssociated == nil ? 0 : 1)
        try budget.checkpoint()
        if destination == nil {
            try budget.reservePixels(ScalarOperationBudget.product(ScalarOperationBudget.product(width, height), channels * 2))
        }
        // Identity transforms need no full-frame algorithm plane. Transformed
        // streams retain signed Int32 planes until their inverse is complete.
        let direct = plan.transforms.isEmpty ? destination : nil
        try ModularImage.admitDescriptors(plan.geometry.channels.count, budget: budget)
        var image = plan.geometry, globalReader = plan.globalReader
        let originalCount = image.channels.count
        try budget.reserveWorkspace(originalCount * MemoryLayout<Int>.stride + 128)
        var written = [Int](repeating: 0, count: originalCount)
        var globalEnd = image.nbMetaChannels
        while globalEnd < originalCount {
            let channel = image.channels[globalEnd]
            if plan.multipleSections && (channel.width > plan.groupDimension || channel.height > plan.groupDimension) { break }
            globalEnd += 1
        }
        // Allocate each admitted algorithm plane once. Group rectangles are
        // independent scratch; all output remains unpublished on any failure.
        if direct == nil {
            for c in image.channels.indices { try image.channels[c].allocatePixels(budget: budget) }
        }
        try decodeChannels(image: &image, count: globalEnd, reader: &globalReader, selected: plan.selected,
                           predictor: plan.header.wpHeader, groupID: 0, budget: budget, destination: direct, bitDepth: plan.bitsPerSample)
        for c in 0..<globalEnd { written[c] = image.channels[c].sampleCount }
        try finishSection(&globalReader, context: "global")
        if plan.multipleSections {
            // No AC-global payload exists for this integer Modular profile.
            guard plan.toc.entrySizes[1 + plan.dcCount] == 0 else { throw ScalarModularError.unsupportedProfile }
            // Large identity images may use bounded group scratch to honour the
            // worker policy; small identity images and worker=1 retain direct
            // destination decoding. No full-frame scratch is added by workers.
            // A direct-output batch never retains every tile in the image.
            let batchLimit = min(budget.maximumWorkers, direct == nil ? plan.groupCount : plan.groupCount - 1)
            let parallel = batchLimit > 1 && plan.groupCount > 1
                && (direct == nil || width * height >= 1024 * 1024)
            try ModularImage.admitDescriptors(image.channels.count, budget: budget)
            let parentGeometry: [ModularChannel] = try image.channels.map {
                try ModularChannel(width: $0.width, height: $0.height, hshift: $0.hshift, vshift: $0.vshift)
            }
            // DC groups remain ordered; only independent AC groups in one pass
            // run together. Previous passes are fully merged before the next.
            for dc in 0..<plan.dcCount {
                var r = try plan.section(1 + dc)
                let result = try decodeGroup(parentChannels: parentGeometry, first: globalEnd,
                    x: (dc % plan.dcX) * plan.dcDimension, y: (dc / plan.dcX) * plan.dcDimension,
                    quantum: plan.dcDimension, minShift: 3, maxShift: 31, groupID: Int32(1 + dc),
                    reader: &r, global: plan.global, bitDepth: plan.bitsPerSample, budget: budget, destination: direct)
                try mergeGroup(result, image: &image, written: &written, bitDepth: plan.bitsPerSample,
                    budget: budget, destination: direct)
            }
            let first = globalEnd
            for pass in 0..<plan.passes {
                if parallel {
                    var base = 0
                    while base < plan.groupCount {
                        let batchBase = base, count = min(batchLimit, plan.groupCount - base)
                        let results = try modularDecodeBatch(count: count, budget: budget) { index in
                            let group = batchBase + index
                            var r = try plan.section(2 + plan.dcCount + pass * plan.groupCount + group)
                            return try decodeGroup(parentChannels: parentGeometry, first: first,
                                x: (group % plan.groupsX) * plan.groupDimension, y: (group / plan.groupsX) * plan.groupDimension,
                                quantum: plan.groupDimension, minShift: plan.brackets[pass].0, maxShift: plan.brackets[pass].1,
                                groupID: Int32(1 + plan.dcCount + pass * plan.groupCount + group),
                                reader: &r, global: plan.global, bitDepth: plan.bitsPerSample, budget: budget)
                        }
                        // The exclusive caller borrow is used only here, after
                        // all workers join. Results own at most one batch of tiles.
                        for result in results {
                            try mergeGroup(result, image: &image, written: &written, bitDepth: plan.bitsPerSample,
                                budget: budget, destination: direct)
                        }
                        base += count
                    }
                } else {
                    for group in 0..<plan.groupCount {
                        var r = try plan.section(2 + plan.dcCount + pass * plan.groupCount + group)
                        let result = try decodeGroup(parentChannels: parentGeometry, first: globalEnd,
                            x: (group % plan.groupsX) * plan.groupDimension, y: (group / plan.groupsX) * plan.groupDimension,
                            quantum: plan.groupDimension, minShift: plan.brackets[pass].0, maxShift: plan.brackets[pass].1,
                            groupID: Int32(1 + plan.dcCount + pass * plan.groupCount + group),
                            reader: &r, global: plan.global, bitDepth: plan.bitsPerSample, budget: budget, destination: direct)
                        try mergeGroup(result, image: &image, written: &written, bitDepth: plan.bitsPerSample,
                            budget: budget, destination: direct)
                    }
                }
            }
        }
        guard image.channels.indices.allSatisfy({ written[$0] == image.channels[$0].sampleCount }) else {
            throw ScalarModularError.invalidInput("Incomplete group coverage")
        }
        if direct == nil {
            try applyInverseTransforms(image: &image, transforms: plan.transforms,
                                       bitDepth: plan.bitsPerSample, budget: budget)
        }
        guard image.nbMetaChannels == 0, image.channels.count == channels else {
            throw ScalarModularError.invalidInput("Invalid restored channel count")
        }
        let maximum = (Int32(1) << plan.bitsPerSample) - 1
        let maxU = UInt32(bitPattern: maximum)
        let rowStep = max(1, 4096 / max(1, width))
        for channel in image.channels {
            guard channel.width == width, channel.height == height, channel.hshift == 0, channel.vshift == 0 else {
                throw ScalarModularError.invalidInput("Invalid restored channel geometry")
            }
        }
        if let destination, channels == 3, !image.channels[0].pixels.isEmpty,
           let raw = destination.bytes.baseAddress {
            let l0 = destination.layouts[0], l1 = destination.layouts[1], l2 = destination.layouts[2]
            if l0.storageBits == 16, l1.storageBits == 16, l2.storageBits == 16,
               l0.littleEndian, l1.littleEndian, l2.littleEndian,
               l0.pixelStride == 6, l1.pixelStride == 6, l2.pixelStride == 6,
               l1.offset == l0.offset + 2, l2.offset == l0.offset + 4,
               l1.rowBytes == l0.rowBytes, l2.rowBytes == l0.rowBytes {
                try image.channels[0].pixels.withUnsafeBufferPointer { b0 in
                    try image.channels[1].pixels.withUnsafeBufferPointer { b1 in
                        try image.channels[2].pixels.withUnsafeBufferPointer { b2 in
                            let p0 = b0.baseAddress!, p1 = b1.baseAddress!, p2 = b2.baseAddress!
                            for y in 0..<height {
                                if y % rowStep == 0 { try budget.checkpoint() }
                                var p = l0.offset &+ y &* l0.rowBytes
                                let srcRow = y &* width
                                var x0 = 0
                                while x0 < width {
                                    if x0 > 0 { try budget.checkpoint() }
                                    let xEnd = min(width, x0 &+ 4096)
                                    for x in x0..<xEnd {
                                        let idx = srcRow &+ x
                                        let s0 = p0[idx], s1 = p1[idx], s2 = p2[idx]
                                        if (UInt32(bitPattern: s0) | UInt32(bitPattern: s1) | UInt32(bitPattern: s2)) > maxU {
                                            throw ScalarModularError.invalidInput("Sample outside declared precision")
                                        }
                                        raw.storeBytes(of: UInt16(truncatingIfNeeded: s0).littleEndian, toByteOffset: p, as: UInt16.self)
                                        raw.storeBytes(of: UInt16(truncatingIfNeeded: s1).littleEndian, toByteOffset: p &+ 2, as: UInt16.self)
                                        raw.storeBytes(of: UInt16(truncatingIfNeeded: s2).littleEndian, toByteOffset: p &+ 4, as: UInt16.self)
                                        p &+= 6
                                    }
                                    x0 = xEnd
                                }
                            }
                        }
                    }
                }
                return ModularDecodedFrame(width: width, height: height, bitsPerSample: plan.bitsPerSample,
                    grayscale: plan.grayscale, alphaAssociated: plan.alphaAssociated,
                    renderingIntent: plan.renderingIntent, transferFunction: plan.transferFunction,
                    iccProfile: plan.iccProfile, image: image)
            } else if l0.storageBits == 8, l1.storageBits == 8, l2.storageBits == 8,
                      l0.pixelStride == 3, l1.pixelStride == 3, l2.pixelStride == 3,
                      l1.offset == l0.offset + 1, l2.offset == l0.offset + 2,
                      l1.rowBytes == l0.rowBytes, l2.rowBytes == l0.rowBytes {
                let base = raw.assumingMemoryBound(to: UInt8.self)
                try image.channels[0].pixels.withUnsafeBufferPointer { b0 in
                    try image.channels[1].pixels.withUnsafeBufferPointer { b1 in
                        try image.channels[2].pixels.withUnsafeBufferPointer { b2 in
                            let p0 = b0.baseAddress!, p1 = b1.baseAddress!, p2 = b2.baseAddress!
                            for y in 0..<height {
                                if y % rowStep == 0 { try budget.checkpoint() }
                                var p = l0.offset &+ y &* l0.rowBytes
                                let srcRow = y &* width
                                var x0 = 0
                                while x0 < width {
                                    if x0 > 0 { try budget.checkpoint() }
                                    let xEnd = min(width, x0 &+ 4096)
                                    for x in x0..<xEnd {
                                        let idx = srcRow &+ x
                                        let s0 = p0[idx], s1 = p1[idx], s2 = p2[idx]
                                        if (UInt32(bitPattern: s0) | UInt32(bitPattern: s1) | UInt32(bitPattern: s2)) > maxU {
                                            throw ScalarModularError.invalidInput("Sample outside declared precision")
                                        }
                                        base[p] = UInt8(truncatingIfNeeded: s0)
                                        base[p &+ 1] = UInt8(truncatingIfNeeded: s1)
                                        base[p &+ 2] = UInt8(truncatingIfNeeded: s2)
                                        p &+= 3
                                    }
                                    x0 = xEnd
                                }
                            }
                        }
                    }
                }
                return ModularDecodedFrame(width: width, height: height, bitsPerSample: plan.bitsPerSample,
                    grayscale: plan.grayscale, alphaAssociated: plan.alphaAssociated,
                    renderingIntent: plan.renderingIntent, transferFunction: plan.transferFunction,
                    iccProfile: plan.iccProfile, image: image)
            }
        }
        for (c, channel) in image.channels.enumerated() {
            let output = destination.map { BorrowedModularChannel(bytes: $0.bytes, layout: $0.layouts[c]) }
            try channel.pixels.withUnsafeBufferPointer { pixels in
                guard !pixels.isEmpty else { return }
                let srcBase = pixels.baseAddress!
                if let output {
                    let base = output.base
                    let layout = output.layout
                    let stride = layout.pixelStride
                    if layout.storageBits == 8 {
                        for y in 0..<height {
                            if y % rowStep == 0 { try budget.checkpoint() }
                            var p = layout.offset &+ y &* layout.rowBytes
                            let srcRow = y &* width
                            var x0 = 0
                            while x0 < width {
                                if x0 > 0 { try budget.checkpoint() }
                                let xEnd = min(width, x0 &+ 4096)
                                for x in x0..<xEnd {
                                    let sample = srcBase[srcRow &+ x]
                                    guard UInt32(bitPattern: sample) <= maxU else {
                                        throw ScalarModularError.invalidInput("Sample outside declared precision")
                                    }
                                    base[p] = UInt8(truncatingIfNeeded: sample)
                                    p &+= stride
                                }
                                x0 = xEnd
                            }
                        }
                    } else if layout.littleEndian {
                        let raw = output.bytes.baseAddress!
                        for y in 0..<height {
                            if y % rowStep == 0 { try budget.checkpoint() }
                            var p = layout.offset &+ y &* layout.rowBytes
                            let srcRow = y &* width
                            var x0 = 0
                            while x0 < width {
                                if x0 > 0 { try budget.checkpoint() }
                                let xEnd = min(width, x0 &+ 4096)
                                for x in x0..<xEnd {
                                    let sample = srcBase[srcRow &+ x]
                                    guard UInt32(bitPattern: sample) <= maxU else {
                                        throw ScalarModularError.invalidInput("Sample outside declared precision")
                                    }
                                    raw.storeBytes(of: UInt16(truncatingIfNeeded: sample).littleEndian, toByteOffset: p, as: UInt16.self)
                                    p &+= stride
                                }
                                x0 = xEnd
                            }
                        }
                    } else {
                        for y in 0..<height {
                            if y % rowStep == 0 { try budget.checkpoint() }
                            var p = layout.offset &+ y &* layout.rowBytes
                            let srcRow = y &* width
                            var x0 = 0
                            while x0 < width {
                                if x0 > 0 { try budget.checkpoint() }
                                let xEnd = min(width, x0 &+ 4096)
                                for x in x0..<xEnd {
                                    let sample = srcBase[srcRow &+ x]
                                    guard UInt32(bitPattern: sample) <= maxU else {
                                        throw ScalarModularError.invalidInput("Sample outside declared precision")
                                    }
                                    base[p] = UInt8(truncatingIfNeeded: sample &>> 8)
                                    base[p &+ 1] = UInt8(truncatingIfNeeded: sample)
                                    p &+= stride
                                }
                                x0 = xEnd
                            }
                        }
                    }
                } else {
                    for i in 0..<pixels.count {
                        if i & 4095 == 0 { try budget.checkpoint() }
                        guard UInt32(bitPattern: srcBase[i]) <= maxU else {
                            throw ScalarModularError.invalidInput("Sample outside declared precision")
                        }
                    }
                }
            }
        }
        return ModularDecodedFrame(width: width, height: height, bitsPerSample: plan.bitsPerSample,
            grayscale: plan.grayscale, alphaAssociated: plan.alphaAssociated,
            renderingIntent: plan.renderingIntent, transferFunction: plan.transferFunction,
            iccProfile: plan.iccProfile, image: image)
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

    private static func makeReader(_ data: Data, budget: ScalarOperationBudget, startingAt: Int = 0, maximumNestingDepth: Int = 32) -> BitReader {
        BitReader(data, startingAt: startingAt, deadline: budget.deadline,
                  maximumNestingDepth: maximumNestingDepth, maximumEntropyTableBytes: 32 * 1024 * 1024, budget: budget)
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
                                       groupID: Int32, budget: ScalarOperationBudget,
                                       destination: BorrowedModularDestination? = nil, bitDepth: Int = 16) throws {
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
        let maxSample = (Int32(1) << bitDepth) - 1
        for c in 0..<count where image.channels[c].sampleCount > 0 {
            let width = image.channels[c].width, height = image.channels[c].height
            try budget.reserveWorkspace(ScalarOperationBudget.sum(192 * (width + 2), 1024))
            if let destination {
                let layout = destination.layouts[c]
                if layout.storageBits == 8 {
                    var plane = BorrowedModularChannel8(bytes: destination.bytes, layout: layout)
                    try decodeModularChannel(width: width, height: height, staticChannel: Int32(c), groupId: groupID,
                        tree: selected.0, stream: &stream, from: &reader, wpHeader: predictor,
                        sampleMaximum: maxSample, out: &plane)
                } else if layout.littleEndian && layout.pixelStride == 2 {
                    var plane = BorrowedModularChannel16LEContiguous(bytes: destination.bytes, layout: layout)
                    try decodeModularChannel(width: width, height: height, staticChannel: Int32(c), groupId: groupID,
                        tree: selected.0, stream: &stream, from: &reader, wpHeader: predictor,
                        sampleMaximum: maxSample, out: &plane)
                } else if layout.littleEndian {
                    var plane = BorrowedModularChannel16LE(bytes: destination.bytes, layout: layout)
                    try decodeModularChannel(width: width, height: height, staticChannel: Int32(c), groupId: groupID,
                        tree: selected.0, stream: &stream, from: &reader, wpHeader: predictor,
                        sampleMaximum: maxSample, out: &plane)
                } else {
                    var plane = BorrowedModularChannel(bytes: destination.bytes, layout: layout)
                    try decodeModularChannel(width: width, height: height, staticChannel: Int32(c), groupId: groupID,
                        tree: selected.0, stream: &stream, from: &reader, wpHeader: predictor,
                        sampleMaximum: maxSample, out: &plane)
                }
            } else {
                var plane: [Int32] = []
                swap(&plane, &image.channels[c].pixels)
                try plane.withUnsafeMutableBufferPointer { buf in
                    var target = buf
                    try decodeModularChannel(width: width, height: height, staticChannel: Int32(c), groupId: groupID,
                        tree: selected.0, stream: &stream, from: &reader, wpHeader: predictor, out: &target)
                }
                image.channels[c].pixels = plane
            }
        }
        if samples > 0 { try stream.finish() }
    }
    private static func decodeGroup(parentChannels: [ModularChannel], first: Int,
                                    x: Int, y: Int, quantum: Int, minShift: Int, maxShift: Int, groupID: Int32,
                                    reader: inout BitReader, global: Entropy?, bitDepth: Int,
                                    budget: ScalarOperationBudget, destination: BorrowedModularDestination? = nil) throws -> GroupResult {
        try budget.checkpoint()
        try ModularImage.admitDescriptors(parentChannels.count - first, budget: budget)
        try budget.reserveWorkspace((parentChannels.count - first) * MemoryLayout<Rect>.stride + 128)
        var rectangles: [Rect] = [], geometry: [ModularChannel] = []
        for c in first..<parentChannels.count {
            let channel = parentChannels[c], shift = min(channel.hshift, channel.vshift)
            guard shift >= minShift, shift <= maxShift else { continue }
            let qx = quantum >> channel.hshift, qy = quantum >> channel.vshift
            guard qx > 0, qy > 0 else { throw ScalarModularError.unsupportedProfile }
            let x0 = x >> channel.hshift, y0 = y >> channel.vshift
            if x0 >= channel.width || y0 >= channel.height { continue }
            let w = min(qx, channel.width - x0), h = min(qy, channel.height - y0)
            geometry.append(try ModularChannel(width: w, height: h, hshift: channel.hshift, vshift: channel.vshift))
            rectangles.append(Rect(channel: c, x: x0, y: y0, width: w, height: h))
        }
        if geometry.isEmpty {
            try finishSection(&reader)
            return GroupResult(image: try ModularImage(channels: []), rectangles: [], wroteDirectly: true)
        }
        let header = try GroupHeader.read(from: &reader)
        let selected = try entropy(header, global: global, reader: &reader, samples: quantum * quantum)
        var subimage = try ModularImage(channels: geometry)
        let transforms = try metaApplyTransforms(image: &subimage, transforms: header.transforms, budget: budget)
        let groupDestination: BorrowedModularDestination?
        if let destination {
            try budget.reserveWorkspace(rectangles.count * MemoryLayout<ModularChannelLayout>.stride + 128)
            let layouts = try rectangles.map { rect in
                try destination.layouts[rect.channel].rectangle(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            }
            groupDestination = BorrowedModularDestination(bytes: destination.bytes, layouts: layouts)
        } else { groupDestination = nil }
        let direct = transforms.isEmpty ? groupDestination : nil
        if direct == nil {
            for c in subimage.channels.indices { try subimage.channels[c].allocatePixels(budget: budget) }
        }
        try decodeChannels(image: &subimage, count: subimage.channels.count, reader: &reader, selected: selected,
                           predictor: header.wpHeader, groupID: groupID, budget: budget, destination: direct, bitDepth: bitDepth)
        try finishSection(&reader)
        if direct == nil {
            try applyInverseTransforms(image: &subimage, transforms: transforms, bitDepth: bitDepth, budget: budget)
        }
        guard subimage.nbMetaChannels == 0, subimage.channels.count == rectangles.count else {
            throw ScalarModularError.invalidInput("Invalid group channel count")
        }
        for index in rectangles.indices {
            guard subimage.channels[index].sameGeometry(as: geometry[index]) else {
                throw ScalarModularError.invalidInput("Invalid group geometry")
            }
        }
        return GroupResult(image: subimage, rectangles: rectangles, wroteDirectly: direct != nil)
    }

    private static func mergeGroup(_ result: GroupResult, image: inout ModularImage, written: inout [Int],
                                   bitDepth: Int, budget: ScalarOperationBudget,
                                   destination: BorrowedModularDestination?) throws {
        try budget.checkpoint()
        let maximum = (Int32(1) << bitDepth) - 1
        let maxU = UInt32(bitPattern: maximum)
        for (index, rect) in result.rectangles.enumerated() {
            let channel = result.image.channels[index]
            let parentWidth = image.channels[rect.channel].width
            let rowStep = max(1, 4096 / max(1, rect.width))
            // Rectangles are checked/clipped to their parent above. These
            // synchronous borrows never escape and no parallel writes occur.
            if let destination {
                if !result.wroteDirectly {
                    let layout = try destination.layouts[rect.channel].rectangle(x: rect.x, y: rect.y,
                        width: rect.width, height: rect.height)
                    let output = BorrowedModularChannel(bytes: destination.bytes, layout: layout)
                    try channel.pixels.withUnsafeBufferPointer { pixels in
                        let srcBase = pixels.baseAddress!
                        let base = output.base
                        let stride = layout.pixelStride
                        if layout.storageBits == 8 {
                            for y in 0..<rect.height {
                                if y % rowStep == 0 { try budget.checkpoint() }
                                var p = layout.offset &+ y &* layout.rowBytes
                                let srcRow = y &* rect.width
                                for x in 0..<rect.width {
                                    if rect.width > 4096 && x > 0 && (x & 4095 == 0) { try budget.checkpoint() }
                                    let sample = srcBase[srcRow &+ x]
                                    guard UInt32(bitPattern: sample) <= maxU else {
                                        throw ScalarModularError.invalidInput("Group sample outside declared precision")
                                    }
                                    base[p] = UInt8(truncatingIfNeeded: sample)
                                    p &+= stride
                                }
                            }
                        } else if layout.littleEndian {
                            let raw = output.bytes.baseAddress!
                            for y in 0..<rect.height {
                                if y % rowStep == 0 { try budget.checkpoint() }
                                var p = layout.offset &+ y &* layout.rowBytes
                                let srcRow = y &* rect.width
                                for x in 0..<rect.width {
                                    if rect.width > 4096 && x > 0 && (x & 4095 == 0) { try budget.checkpoint() }
                                    let sample = srcBase[srcRow &+ x]
                                    guard UInt32(bitPattern: sample) <= maxU else {
                                        throw ScalarModularError.invalidInput("Group sample outside declared precision")
                                    }
                                    raw.storeBytes(of: UInt16(truncatingIfNeeded: sample).littleEndian, toByteOffset: p, as: UInt16.self)
                                    p &+= stride
                                }
                            }
                        } else {
                            for y in 0..<rect.height {
                                if y % rowStep == 0 { try budget.checkpoint() }
                                var p = layout.offset &+ y &* layout.rowBytes
                                let srcRow = y &* rect.width
                                for x in 0..<rect.width {
                                    if rect.width > 4096 && x > 0 && (x & 4095 == 0) { try budget.checkpoint() }
                                    let sample = srcBase[srcRow &+ x]
                                    guard UInt32(bitPattern: sample) <= maxU else {
                                        throw ScalarModularError.invalidInput("Group sample outside declared precision")
                                    }
                                    base[p] = UInt8(truncatingIfNeeded: sample &>> 8)
                                    base[p &+ 1] = UInt8(truncatingIfNeeded: sample)
                                    p &+= stride
                                }
                            }
                        }
                    }
                }
            } else {
                try image.channels[rect.channel].pixels.withUnsafeMutableBufferPointer { destination in
                    try channel.pixels.withUnsafeBufferPointer { source in
                        let dstBase = destination.baseAddress!
                        let srcBase = source.baseAddress!
                        for row in 0..<rect.height {
                            if row % rowStep == 0 { try budget.checkpoint() }
                            let offset = (rect.y &+ row) &* parentWidth &+ rect.x
                            let srcOffset = row &* rect.width
                            var c0 = 0
                            while c0 < rect.width {
                                if c0 > 0 { try budget.checkpoint() }
                                let chunk = min(rect.width - c0, 4096)
                                (dstBase + offset + c0).update(from: srcBase + srcOffset + c0, count: chunk)
                                c0 &+= chunk
                            }
                        }
                    }
                }
            }
            written[rect.channel] = try ScalarOperationBudget.sum(written[rect.channel], channel.sampleCount)
        }
    }
}
