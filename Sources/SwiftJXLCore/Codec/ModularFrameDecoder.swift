// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Full-frame integer Modular JPEG XL decoder (ISO/IEC 18181-1 §§8, 9.1–9.2).
package enum ModularFrameDecoder {
    package typealias EntropyBundle = (
        tree: ModularTree,
        header: EntropySectionHeader,
        codebook: MultiClusterCodebook
    )

    package struct DecodedFrame: Sendable {
        package let width: Int
        package let height: Int
        package let bitsPerSample: Int
        package let grayscale: Bool
        package let alphaAssociated: Bool?
        package let iccProfile: Data?
        package let renderingIntent: RenderingIntent
        package let transferFunction: TransferFunction
        package let image: ModularImage
    }

    package struct Prepared: Sendable {
        package let width: Int
        package let height: Int
        package let bitsPerSample: Int
        package let grayscale: Bool
        package let alphaAssociated: Bool?
        package let iccProfile: Data?
        package let renderingIntent: RenderingIntent
        package let transferFunction: TransferFunction

        fileprivate let codestream: Data
        fileprivate let toc: TOC
        fileprivate let payloadStart: Int
        fileprivate let groupDim: Int
        fileprivate let dcGroupDim: Int
        fileprivate let groupsX: Int
        fileprivate let groupsY: Int
        fileprivate let dcGroupsX: Int
        fileprivate let dcGroupsY: Int
        fileprivate let passes: Passes
        fileprivate let channelsCount: Int
        fileprivate let initialTransformedImage: ModularImage
        fileprivate let globalTransforms: [ModularTransform]
        fileprivate let globalGroupHeader: GroupHeader
        fileprivate let globalEntropy: EntropyBundle?
        fileprivate let sec0ReaderAfterHeader: BitReader
        fileprivate let budget: ScalarOperationBudget
        fileprivate let maximumNestingDepth: Int

        package func decode(
            into bytes: UnsafeMutableRawBufferPointer,
            layouts: [ModularChannelLayout]
        ) throws {
            try budget.checkpoint()
            guard layouts.count == channelsCount,
                  layouts.allSatisfy({
                      $0.width == width
                          && $0.height == height
                          && $0.storageBits >= bitsPerSample
                          && $0.requiredBytes <= bytes.count
                  }) else {
                throw ScalarModularError.invalidInput("Modular destination layout does not match frame")
            }
            try budget.reservePixels(bytes.count)
            try budget.reserveWorkspace(1024)

            let sampleMax = (Int32(1) << bitsPerSample) - 1
            let numGroups = groupsX * groupsY

            if numGroups == 1 && passes.numPasses == 1 {
                try decodeSingleSection(into: bytes, layouts: layouts, sampleMax: sampleMax)
            } else {
                try decodeMultiSection(into: bytes, layouts: layouts, sampleMax: sampleMax)
            }
            try budget.checkpoint()
        }

        fileprivate func decodeToImage() throws -> ModularImage {
            try budget.checkpoint()
            let sampleMax = (Int32(1) << bitsPerSample) - 1
            let numGroups = groupsX * groupsY
            if numGroups == 1 && passes.numPasses == 1 {
                return try decodeSingleSectionToImage(sampleMax: sampleMax)
            } else {
                return try decodeMultiSectionToImage(sampleMax: sampleMax)
            }
        }

        private func selectEntropy(
            header: GroupHeader,
            from reader: inout BitReader,
            pixelCount: Int
        ) throws -> EntropyBundle {
            if header.useGlobalTree {
                guard let globalEntropy else {
                    throw ScalarModularError.invalidInput("Missing global Modular tree")
                }
                return globalEntropy
            }
            let raw = try ScalarModularDecoder.readTreeAndCodebook(
                from: &reader,
                pixelCount: pixelCount
            )
            return (raw.0, raw.1, raw.2)
        }

        private func decodeChannelIntoLayout(
            bytes: UnsafeMutableRawBufferPointer,
            layout: ModularChannelLayout,
            staticChannel: Int32,
            groupId: Int32,
            tree: ModularTree,
            stream: inout TokenStreamReader,
            from reader: inout BitReader,
            wpHeader: WeightedPredictorHeader,
            sampleMaximum: Int32
        ) throws {
            try budget.reserveWorkspace(
                ScalarOperationBudget.sum(
                    ScalarOperationBudget.product(layout.width + 2, 192),
                    1024
                )
            )
            if layout.storageBits == 8 {
                var target = BorrowedModularChannel8(bytes: bytes, layout: layout)
                try decodeModularChannel(
                    width: layout.width,
                    height: layout.height,
                    staticChannel: staticChannel,
                    groupId: groupId,
                    tree: tree,
                    stream: &stream,
                    from: &reader,
                    wpHeader: wpHeader,
                    sampleMaximum: sampleMaximum,
                    out: &target
                )
            } else if layout.littleEndian && layout.pixelStride == 2 {
                var target = BorrowedModularChannel16LEContiguous(bytes: bytes, layout: layout)
                try decodeModularChannel(
                    width: layout.width,
                    height: layout.height,
                    staticChannel: staticChannel,
                    groupId: groupId,
                    tree: tree,
                    stream: &stream,
                    from: &reader,
                    wpHeader: wpHeader,
                    sampleMaximum: sampleMaximum,
                    out: &target
                )
            } else if layout.littleEndian {
                var target = BorrowedModularChannel16LE(bytes: bytes, layout: layout)
                try decodeModularChannel(
                    width: layout.width,
                    height: layout.height,
                    staticChannel: staticChannel,
                    groupId: groupId,
                    tree: tree,
                    stream: &stream,
                    from: &reader,
                    wpHeader: wpHeader,
                    sampleMaximum: sampleMaximum,
                    out: &target
                )
            } else {
                var target = BorrowedModularChannel(bytes: bytes, layout: layout)
                try decodeModularChannel(
                    width: layout.width,
                    height: layout.height,
                    staticChannel: staticChannel,
                    groupId: groupId,
                    tree: tree,
                    stream: &stream,
                    from: &reader,
                    wpHeader: wpHeader,
                    sampleMaximum: sampleMaximum,
                    out: &target
                )
            }
        }

        private func decodeChannelIntoArray(
            channel: inout ModularChannel,
            staticChannel: Int32,
            groupId: Int32,
            tree: ModularTree,
            stream: inout TokenStreamReader,
            from reader: inout BitReader,
            wpHeader: WeightedPredictorHeader,
            sampleMaximum: Int32?
        ) throws {
            if channel.sampleCount == 0 { return }
            try budget.reserveWorkspace(
                ScalarOperationBudget.sum(
                    ScalarOperationBudget.product(channel.width + 2, 192),
                    1024
                )
            )
            try channel.pixels.withUnsafeMutableBufferPointer { ptr in
                var target = ptr
                try decodeModularChannel(
                    width: channel.width,
                    height: channel.height,
                    staticChannel: staticChannel,
                    groupId: groupId,
                    tree: tree,
                    stream: &stream,
                    from: &reader,
                    wpHeader: wpHeader,
                    sampleMaximum: sampleMaximum,
                    out: &target
                )
            }
        }

        private func writePlanesToLayouts(
            _ channels: [ModularChannel],
            into bytes: UnsafeMutableRawBufferPointer,
            layouts: [ModularChannelLayout],
            sampleMax: Int32
        ) throws {
            guard channels.count == layouts.count else {
                throw ScalarModularError.invalidInput("Decoded channel count mismatch")
            }
            let maxU = UInt32(bitPattern: sampleMax)
            for c in 0..<channels.count {
                let ch = channels[c]
                let layout = layouts[c]
                guard ch.width == layout.width,
                      ch.height == layout.height,
                      ch.pixels.count == ch.sampleCount else {
                    throw ScalarModularError.invalidInput("Decoded channel geometry mismatch")
                }
            }

            if layouts.count == 3 {
                let l0 = layouts[0], l1 = layouts[1], l2 = layouts[2]
                let w = l0.width, h = l0.height
                if l0.storageBits == 8 && l1.storageBits == 8 && l2.storageBits == 8
                    && l0.pixelStride == 3 && l1.pixelStride == 3 && l2.pixelStride == 3
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes
                    && l0.offset == 0 && l1.offset == 1 && l2.offset == 2 {
                    let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let rowBytes = l0.rowBytes
                    let rowStep = max(1, 4096 / max(1, w))
                    try channels[0].pixels.withUnsafeBufferPointer { b0 in
                        try channels[1].pixels.withUnsafeBufferPointer { b1 in
                            try channels[2].pixels.withUnsafeBufferPointer { b2 in
                                guard let p0 = b0.baseAddress, let p1 = b1.baseAddress, let p2 = b2.baseAddress else { return }
                                for ry in 0..<h {
                                    if ry % rowStep == 0 { try budget.checkpoint() }
                                    let srcRow = ry * w
                                    var dstPos = ry * rowBytes
                                    for rx in 0..<w {
                                        let v0 = p0[srcRow + rx]
                                        let v1 = p1[srcRow + rx]
                                        let v2 = p2[srcRow + rx]
                                        guard (UInt32(bitPattern: v0) | UInt32(bitPattern: v1) | UInt32(bitPattern: v2)) <= maxU else {
                                            throw ScalarModularError.invalidInput("Sample outside declared precision")
                                        }
                                        rawBase[dstPos] = UInt8(truncatingIfNeeded: v0)
                                        rawBase[dstPos + 1] = UInt8(truncatingIfNeeded: v1)
                                        rawBase[dstPos + 2] = UInt8(truncatingIfNeeded: v2)
                                        dstPos += 3
                                    }
                                }
                            }
                        }
                    }
                    return
                }
                if l0.storageBits == 16 && l1.storageBits == 16 && l2.storageBits == 16
                    && l0.littleEndian && l1.littleEndian && l2.littleEndian
                    && l0.pixelStride == 6 && l1.pixelStride == 6 && l2.pixelStride == 6
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes
                    && l0.offset == 0 && l1.offset == 2 && l2.offset == 4 {
                    let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let rowBytes = l0.rowBytes
                    let rowStep = max(1, 4096 / max(1, w))
                    try channels[0].pixels.withUnsafeBufferPointer { b0 in
                        try channels[1].pixels.withUnsafeBufferPointer { b1 in
                            try channels[2].pixels.withUnsafeBufferPointer { b2 in
                                guard let p0 = b0.baseAddress, let p1 = b1.baseAddress, let p2 = b2.baseAddress else { return }
                                for ry in 0..<h {
                                    if ry % rowStep == 0 { try budget.checkpoint() }
                                    let srcRow = ry * w
                                    var dstPos = ry * rowBytes
                                    for rx in 0..<w {
                                        let v0 = p0[srcRow + rx]
                                        let v1 = p1[srcRow + rx]
                                        let v2 = p2[srcRow + rx]
                                        guard (UInt32(bitPattern: v0) | UInt32(bitPattern: v1) | UInt32(bitPattern: v2)) <= maxU else {
                                            throw ScalarModularError.invalidInput("Sample outside declared precision")
                                        }
                                        rawBase[dstPos] = UInt8(truncatingIfNeeded: v0)
                                        rawBase[dstPos + 1] = UInt8(truncatingIfNeeded: v0 >> 8)
                                        rawBase[dstPos + 2] = UInt8(truncatingIfNeeded: v1)
                                        rawBase[dstPos + 3] = UInt8(truncatingIfNeeded: v1 >> 8)
                                        rawBase[dstPos + 4] = UInt8(truncatingIfNeeded: v2)
                                        rawBase[dstPos + 5] = UInt8(truncatingIfNeeded: v2 >> 8)
                                        dstPos += 6
                                    }
                                }
                            }
                        }
                    }
                    return
                }
            } else if layouts.count == 4 {
                let l0 = layouts[0], l1 = layouts[1], l2 = layouts[2], l3 = layouts[3]
                let w = l0.width, h = l0.height
                if l0.storageBits == 8 && l1.storageBits == 8 && l2.storageBits == 8 && l3.storageBits == 8
                    && l0.pixelStride == 4 && l1.pixelStride == 4 && l2.pixelStride == 4 && l3.pixelStride == 4
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes && l2.rowBytes == l3.rowBytes
                    && l0.offset == 0 && l1.offset == 1 && l2.offset == 2 && l3.offset == 3 {
                    let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let rowBytes = l0.rowBytes
                    let rowStep = max(1, 4096 / max(1, w))
                    try channels[0].pixels.withUnsafeBufferPointer { b0 in
                        try channels[1].pixels.withUnsafeBufferPointer { b1 in
                            try channels[2].pixels.withUnsafeBufferPointer { b2 in
                                try channels[3].pixels.withUnsafeBufferPointer { b3 in
                                    guard let p0 = b0.baseAddress, let p1 = b1.baseAddress, let p2 = b2.baseAddress, let p3 = b3.baseAddress else { return }
                                    for ry in 0..<h {
                                        if ry % rowStep == 0 { try budget.checkpoint() }
                                        let srcRow = ry * w
                                        var dstPos = ry * rowBytes
                                        for rx in 0..<w {
                                            let v0 = p0[srcRow + rx]
                                            let v1 = p1[srcRow + rx]
                                            let v2 = p2[srcRow + rx]
                                            let v3 = p3[srcRow + rx]
                                            guard (UInt32(bitPattern: v0) | UInt32(bitPattern: v1) | UInt32(bitPattern: v2) | UInt32(bitPattern: v3)) <= maxU else {
                                                throw ScalarModularError.invalidInput("Sample outside declared precision")
                                            }
                                            rawBase[dstPos] = UInt8(truncatingIfNeeded: v0)
                                            rawBase[dstPos + 1] = UInt8(truncatingIfNeeded: v1)
                                            rawBase[dstPos + 2] = UInt8(truncatingIfNeeded: v2)
                                            rawBase[dstPos + 3] = UInt8(truncatingIfNeeded: v3)
                                            dstPos += 4
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return
                }
                if l0.storageBits == 16 && l1.storageBits == 16 && l2.storageBits == 16 && l3.storageBits == 16
                    && l0.littleEndian && l1.littleEndian && l2.littleEndian && l3.littleEndian
                    && l0.pixelStride == 8 && l1.pixelStride == 8 && l2.pixelStride == 8 && l3.pixelStride == 8
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes && l2.rowBytes == l3.rowBytes
                    && l0.offset == 0 && l1.offset == 2 && l2.offset == 4 && l3.offset == 6 {
                    let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let rowBytes = l0.rowBytes
                    let rowStep = max(1, 4096 / max(1, w))
                    try channels[0].pixels.withUnsafeBufferPointer { b0 in
                        try channels[1].pixels.withUnsafeBufferPointer { b1 in
                            try channels[2].pixels.withUnsafeBufferPointer { b2 in
                                try channels[3].pixels.withUnsafeBufferPointer { b3 in
                                    guard let p0 = b0.baseAddress, let p1 = b1.baseAddress, let p2 = b2.baseAddress, let p3 = b3.baseAddress else { return }
                                    for ry in 0..<h {
                                        if ry % rowStep == 0 { try budget.checkpoint() }
                                        let srcRow = ry * w
                                        var dstPos = ry * rowBytes
                                        for rx in 0..<w {
                                            let v0 = p0[srcRow + rx]
                                            let v1 = p1[srcRow + rx]
                                            let v2 = p2[srcRow + rx]
                                            let v3 = p3[srcRow + rx]
                                            guard (UInt32(bitPattern: v0) | UInt32(bitPattern: v1) | UInt32(bitPattern: v2) | UInt32(bitPattern: v3)) <= maxU else {
                                                throw ScalarModularError.invalidInput("Sample outside declared precision")
                                            }
                                            rawBase[dstPos] = UInt8(truncatingIfNeeded: v0)
                                            rawBase[dstPos + 1] = UInt8(truncatingIfNeeded: v0 >> 8)
                                            rawBase[dstPos + 2] = UInt8(truncatingIfNeeded: v1)
                                            rawBase[dstPos + 3] = UInt8(truncatingIfNeeded: v1 >> 8)
                                            rawBase[dstPos + 4] = UInt8(truncatingIfNeeded: v2)
                                            rawBase[dstPos + 5] = UInt8(truncatingIfNeeded: v2 >> 8)
                                            rawBase[dstPos + 6] = UInt8(truncatingIfNeeded: v3)
                                            rawBase[dstPos + 7] = UInt8(truncatingIfNeeded: v3 >> 8)
                                            dstPos += 8
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return
                }
            }

            for c in 0..<channels.count {
                let ch = channels[c]
                let layout = layouts[c]
                try writeRectangleToLayout(
                    source: ch.pixels,
                    rectX: 0,
                    rectY: 0,
                    rectW: ch.width,
                    rectH: ch.height,
                    into: bytes,
                    layout: layout,
                    maxU: maxU
                )
            }
        }

        private func writeRectangleToLayout(
            source: [Int32],
            rectX: Int,
            rectY: Int,
            rectW: Int,
            rectH: Int,
            into bytes: UnsafeMutableRawBufferPointer,
            layout: ModularChannelLayout,
            maxU: UInt32
        ) throws {
            guard source.count == rectW * rectH else {
                throw ScalarModularError.invalidInput("Invalid rectangle sample count")
            }
            let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let stride = layout.pixelStride
            let rowStep = max(1, 4096 / max(1, rectW))
            try source.withUnsafeBufferPointer { srcBuf in
                guard let src = srcBuf.baseAddress else { return }
                if layout.storageBits == 8 {
                    for ry in 0..<rectH {
                        if ry % rowStep == 0 { try budget.checkpoint() }
                        let srcRow = ry * rectW
                        var dstPos = layout.offset + (rectY + ry) * layout.rowBytes + rectX * stride
                        for rx in 0..<rectW {
                            let val = src[srcRow + rx]
                            guard UInt32(bitPattern: val) <= maxU else {
                                throw ScalarModularError.invalidInput("Sample outside declared precision")
                            }
                            rawBase[dstPos] = UInt8(truncatingIfNeeded: val)
                            dstPos += stride
                        }
                    }
                } else if layout.littleEndian {
                    for ry in 0..<rectH {
                        if ry % rowStep == 0 { try budget.checkpoint() }
                        let srcRow = ry * rectW
                        var dstPos = layout.offset + (rectY + ry) * layout.rowBytes + rectX * stride
                        for rx in 0..<rectW {
                            let val = src[srcRow + rx]
                            guard UInt32(bitPattern: val) <= maxU else {
                                throw ScalarModularError.invalidInput("Sample outside declared precision")
                            }
                            rawBase[dstPos] = UInt8(truncatingIfNeeded: val)
                            rawBase[dstPos + 1] = UInt8(truncatingIfNeeded: val >> 8)
                            dstPos += stride
                        }
                    }
                } else {
                    for ry in 0..<rectH {
                        if ry % rowStep == 0 { try budget.checkpoint() }
                        let srcRow = ry * rectW
                        var dstPos = layout.offset + (rectY + ry) * layout.rowBytes + rectX * stride
                        for rx in 0..<rectW {
                            let val = src[srcRow + rx]
                            guard UInt32(bitPattern: val) <= maxU else {
                                throw ScalarModularError.invalidInput("Sample outside declared precision")
                            }
                            rawBase[dstPos] = UInt8(truncatingIfNeeded: val >> 8)
                            rawBase[dstPos + 1] = UInt8(truncatingIfNeeded: val)
                            dstPos += stride
                        }
                    }
                }
            }
        }

        private func decodeSingleSection(
            into bytes: UnsafeMutableRawBufferPointer,
            layouts: [ModularChannelLayout],
            sampleMax: Int32
        ) throws {
            var reader = sec0ReaderAfterHeader
            let entropy = try selectEntropy(
                header: globalGroupHeader,
                from: &reader,
                pixelCount: width * height
            )
            try budget.reserveWorkspace(
                ScalarOperationBudget.product(entropy.codebook.ansCounts.count, 64 * 1024)
            )
            let maxWidth = initialTransformedImage.channels.map(\.width).max() ?? 0
            var stream = TokenStreamReader(
                header: entropy.header,
                codebook: entropy.codebook,
                distanceMultiplier: maxWidth
            )

            if globalTransforms.isEmpty {
                for c in 0..<channelsCount {
                    try decodeChannelIntoLayout(
                        bytes: bytes,
                        layout: layouts[c],
                        staticChannel: Int32(c),
                        groupId: 0,
                        tree: entropy.tree,
                        stream: &stream,
                        from: &reader,
                        wpHeader: globalGroupHeader.wpHeader,
                        sampleMaximum: sampleMax
                    )
                }
                try stream.finish(from: &reader)
                try reader.expectZeroPadding()
                guard reader.isExhausted else {
                    throw ScalarModularError.invalidInput("Unexpected trailing bytes in Modular section")
                }
            } else {
                var working = initialTransformedImage
                for i in working.channels.indices {
                    try working.channels[i].allocatePixels(budget: budget)
                    try decodeChannelIntoArray(
                        channel: &working.channels[i],
                        staticChannel: Int32(i),
                        groupId: 0,
                        tree: entropy.tree,
                        stream: &stream,
                        from: &reader,
                        wpHeader: globalGroupHeader.wpHeader,
                        sampleMaximum: nil
                    )
                }
                try stream.finish(from: &reader)
                try reader.expectZeroPadding()
                guard reader.isExhausted else {
                    throw ScalarModularError.invalidInput("Unexpected trailing bytes in Modular section")
                }
                if globalTransforms.count == 1,
                   globalTransforms[0].id == .rct,
                   globalTransforms[0].beginC == 0,
                   globalTransforms[0].rctType == 6,
                   working.nbMetaChannels == 0,
                   try writePlanesToLayoutsWithRCT6(
                       working.channels,
                       into: bytes,
                       layouts: layouts,
                       sampleMax: sampleMax
                   ) {
                    return
                }
                try applyInverseTransforms(
                    image: &working,
                    transforms: globalTransforms,
                    bitDepth: bitsPerSample,
                    budget: budget
                )
                try writePlanesToLayouts(
                    working.channels,
                    into: bytes,
                    layouts: layouts,
                    sampleMax: sampleMax
                )
            }
        }

        private func writePlanesToLayoutsWithRCT6(
            _ channels: [ModularChannel],
            into bytes: UnsafeMutableRawBufferPointer,
            layouts: [ModularChannelLayout],
            sampleMax: Int32
        ) throws -> Bool {
            guard channels.count == layouts.count, channels.count == 3 || channels.count == 4 else {
                return false
            }
            let l0 = layouts[0], l1 = layouts[1], l2 = layouts[2]
            let w = l0.width, h = l0.height
            for c in 0..<channels.count {
                let ch = channels[c]
                let layout = layouts[c]
                guard ch.width == w, ch.height == h,
                      layout.width == w, layout.height == h,
                      ch.hshift == 0, ch.vshift == 0,
                      ch.pixels.count == ch.sampleCount else {
                    return false
                }
            }
            let maxU = UInt32(bitPattern: sampleMax)
            let rowStep = max(1, 4096 / max(1, w))
            if layouts.count == 3 {
                if l0.storageBits == 8 && l1.storageBits == 8 && l2.storageBits == 8
                    && l0.pixelStride == 3 && l1.pixelStride == 3 && l2.pixelStride == 3
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes
                    && l0.offset == 0 && l1.offset == 1 && l2.offset == 2 {
                    let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let rowBytes = l0.rowBytes
                    try channels[0].pixels.withUnsafeBufferPointer { b0 in
                        try channels[1].pixels.withUnsafeBufferPointer { b1 in
                            try channels[2].pixels.withUnsafeBufferPointer { b2 in
                                guard let p0 = b0.baseAddress, let p1 = b1.baseAddress, let p2 = b2.baseAddress else { return }
                                for ry in 0..<h {
                                    if ry % rowStep == 0 { try budget.checkpoint() }
                                    let srcRow = ry &* w
                                    var dstPos = ry &* rowBytes
                                    for rx in 0..<w {
                                        let i = srcRow &+ rx
                                        let y0 = p0[i], y1 = p1[i], y2 = p2[i]
                                        let tmp = y0 &- (y2 >> 1)
                                        let g = y2 &+ tmp
                                        let b = tmp &- (y1 >> 1)
                                        let r = b &+ y1
                                        guard (UInt32(bitPattern: r) | UInt32(bitPattern: g) | UInt32(bitPattern: b)) <= maxU else {
                                            throw ScalarModularError.invalidInput("Sample outside declared precision")
                                        }
                                        rawBase[dstPos] = UInt8(truncatingIfNeeded: r)
                                        rawBase[dstPos &+ 1] = UInt8(truncatingIfNeeded: g)
                                        rawBase[dstPos &+ 2] = UInt8(truncatingIfNeeded: b)
                                        dstPos &+= 3
                                    }
                                }
                            }
                        }
                    }
                    return true
                }
                if l0.storageBits == 16 && l1.storageBits == 16 && l2.storageBits == 16
                    && l0.littleEndian && l1.littleEndian && l2.littleEndian
                    && l0.pixelStride == 6 && l1.pixelStride == 6 && l2.pixelStride == 6
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes
                    && l0.offset == 0 && l1.offset == 2 && l2.offset == 4 {
                    let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let rowBytes = l0.rowBytes
                    try channels[0].pixels.withUnsafeBufferPointer { b0 in
                        try channels[1].pixels.withUnsafeBufferPointer { b1 in
                            try channels[2].pixels.withUnsafeBufferPointer { b2 in
                                guard let p0 = b0.baseAddress, let p1 = b1.baseAddress, let p2 = b2.baseAddress else { return }
                                for ry in 0..<h {
                                    if ry % rowStep == 0 { try budget.checkpoint() }
                                    let srcRow = ry &* w
                                    var dstPos = ry &* rowBytes
                                    for rx in 0..<w {
                                        let i = srcRow &+ rx
                                        let y0 = p0[i], y1 = p1[i], y2 = p2[i]
                                        let tmp = y0 &- (y2 >> 1)
                                        let g = y2 &+ tmp
                                        let b = tmp &- (y1 >> 1)
                                        let r = b &+ y1
                                        guard (UInt32(bitPattern: r) | UInt32(bitPattern: g) | UInt32(bitPattern: b)) <= maxU else {
                                            throw ScalarModularError.invalidInput("Sample outside declared precision")
                                        }
                                        rawBase[dstPos] = UInt8(truncatingIfNeeded: r)
                                        rawBase[dstPos &+ 1] = UInt8(truncatingIfNeeded: r >> 8)
                                        rawBase[dstPos &+ 2] = UInt8(truncatingIfNeeded: g)
                                        rawBase[dstPos &+ 3] = UInt8(truncatingIfNeeded: g >> 8)
                                        rawBase[dstPos &+ 4] = UInt8(truncatingIfNeeded: b)
                                        rawBase[dstPos &+ 5] = UInt8(truncatingIfNeeded: b >> 8)
                                        dstPos &+= 6
                                    }
                                }
                            }
                        }
                    }
                    return true
                }
            } else if layouts.count == 4 {
                let l3 = layouts[3]
                if l0.storageBits == 8 && l1.storageBits == 8 && l2.storageBits == 8 && l3.storageBits == 8
                    && l0.pixelStride == 4 && l1.pixelStride == 4 && l2.pixelStride == 4 && l3.pixelStride == 4
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes && l2.rowBytes == l3.rowBytes
                    && l0.offset == 0 && l1.offset == 1 && l2.offset == 2 && l3.offset == 3 {
                    let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let rowBytes = l0.rowBytes
                    try channels[0].pixels.withUnsafeBufferPointer { b0 in
                        try channels[1].pixels.withUnsafeBufferPointer { b1 in
                            try channels[2].pixels.withUnsafeBufferPointer { b2 in
                                try channels[3].pixels.withUnsafeBufferPointer { b3 in
                                    guard let p0 = b0.baseAddress, let p1 = b1.baseAddress, let p2 = b2.baseAddress, let p3 = b3.baseAddress else { return }
                                    for ry in 0..<h {
                                        if ry % rowStep == 0 { try budget.checkpoint() }
                                        let srcRow = ry &* w
                                        var dstPos = ry &* rowBytes
                                        for rx in 0..<w {
                                            let i = srcRow &+ rx
                                            let y0 = p0[i], y1 = p1[i], y2 = p2[i], a = p3[i]
                                            let tmp = y0 &- (y2 >> 1)
                                            let g = y2 &+ tmp
                                            let b = tmp &- (y1 >> 1)
                                            let r = b &+ y1
                                            guard (UInt32(bitPattern: r) | UInt32(bitPattern: g) | UInt32(bitPattern: b) | UInt32(bitPattern: a)) <= maxU else {
                                                throw ScalarModularError.invalidInput("Sample outside declared precision")
                                            }
                                            rawBase[dstPos] = UInt8(truncatingIfNeeded: r)
                                            rawBase[dstPos &+ 1] = UInt8(truncatingIfNeeded: g)
                                            rawBase[dstPos &+ 2] = UInt8(truncatingIfNeeded: b)
                                            rawBase[dstPos &+ 3] = UInt8(truncatingIfNeeded: a)
                                            dstPos &+= 4
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return true
                }
                if l0.storageBits == 16 && l1.storageBits == 16 && l2.storageBits == 16 && l3.storageBits == 16
                    && l0.littleEndian && l1.littleEndian && l2.littleEndian && l3.littleEndian
                    && l0.pixelStride == 8 && l1.pixelStride == 8 && l2.pixelStride == 8 && l3.pixelStride == 8
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes && l2.rowBytes == l3.rowBytes
                    && l0.offset == 0 && l1.offset == 2 && l2.offset == 4 && l3.offset == 6 {
                    let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let rowBytes = l0.rowBytes
                    try channels[0].pixels.withUnsafeBufferPointer { b0 in
                        try channels[1].pixels.withUnsafeBufferPointer { b1 in
                            try channels[2].pixels.withUnsafeBufferPointer { b2 in
                                try channels[3].pixels.withUnsafeBufferPointer { b3 in
                                    guard let p0 = b0.baseAddress, let p1 = b1.baseAddress, let p2 = b2.baseAddress, let p3 = b3.baseAddress else { return }
                                    for ry in 0..<h {
                                        if ry % rowStep == 0 { try budget.checkpoint() }
                                        let srcRow = ry &* w
                                        var dstPos = ry &* rowBytes
                                        for rx in 0..<w {
                                            let i = srcRow &+ rx
                                            let y0 = p0[i], y1 = p1[i], y2 = p2[i], a = p3[i]
                                            let tmp = y0 &- (y2 >> 1)
                                            let g = y2 &+ tmp
                                            let b = tmp &- (y1 >> 1)
                                            let r = b &+ y1
                                            guard (UInt32(bitPattern: r) | UInt32(bitPattern: g) | UInt32(bitPattern: b) | UInt32(bitPattern: a)) <= maxU else {
                                                throw ScalarModularError.invalidInput("Sample outside declared precision")
                                            }
                                            rawBase[dstPos] = UInt8(truncatingIfNeeded: r)
                                            rawBase[dstPos &+ 1] = UInt8(truncatingIfNeeded: r >> 8)
                                            rawBase[dstPos &+ 2] = UInt8(truncatingIfNeeded: g)
                                            rawBase[dstPos &+ 3] = UInt8(truncatingIfNeeded: g >> 8)
                                            rawBase[dstPos &+ 4] = UInt8(truncatingIfNeeded: b)
                                            rawBase[dstPos &+ 5] = UInt8(truncatingIfNeeded: b >> 8)
                                            rawBase[dstPos &+ 6] = UInt8(truncatingIfNeeded: a)
                                            rawBase[dstPos &+ 7] = UInt8(truncatingIfNeeded: a >> 8)
                                            dstPos &+= 8
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return true
                }
            }
            return false
        }

        private func decodeSingleSectionToImage(sampleMax: Int32) throws -> ModularImage {
            var reader = sec0ReaderAfterHeader
            let entropy = try selectEntropy(
                header: globalGroupHeader,
                from: &reader,
                pixelCount: width * height
            )
            try budget.reserveWorkspace(
                ScalarOperationBudget.product(entropy.codebook.ansCounts.count, 64 * 1024)
            )
            let maxWidth = initialTransformedImage.channels.map(\.width).max() ?? 0
            var stream = TokenStreamReader(
                header: entropy.header,
                codebook: entropy.codebook,
                distanceMultiplier: maxWidth
            )
            var working = initialTransformedImage
            let directSampleMax: Int32? = globalTransforms.isEmpty ? sampleMax : nil
            for i in working.channels.indices {
                try working.channels[i].allocatePixels(budget: budget)
                try decodeChannelIntoArray(
                    channel: &working.channels[i],
                    staticChannel: Int32(i),
                    groupId: 0,
                    tree: entropy.tree,
                    stream: &stream,
                    from: &reader,
                    wpHeader: globalGroupHeader.wpHeader,
                    sampleMaximum: directSampleMax
                )
            }
            try stream.finish(from: &reader)
            try reader.expectZeroPadding()
            guard reader.isExhausted else {
                throw ScalarModularError.invalidInput("Unexpected trailing bytes in Modular section")
            }
            if !globalTransforms.isEmpty {
                try applyInverseTransforms(
                    image: &working,
                    transforms: globalTransforms,
                    bitDepth: bitsPerSample,
                    budget: budget
                )
                try validateSamplesInRange(working, sampleMax: sampleMax)
            }
            return working
        }

        private func sectionReader(_ index: Int) throws -> BitReader {
            try budget.checkpoint()
            guard toc.entrySizes.indices.contains(index),
                  let offset = Int(exactly: toc.offsets[index]) else {
                throw ScalarModularError.invalidInput("Invalid Modular TOC section index")
            }
            let length = Int(toc.entrySizes[index])
            try budget.reserveWorkspace(ScalarOperationBudget.product(length, 2))
            let range = (payloadStart + offset)..<(payloadStart + offset + length)
            return BitReader(
                codestream.subdata(in: range),
                deadline: budget.deadline,
                maximumNestingDepth: maximumNestingDepth,
                budget: budget
            )
        }

        private func firstNonGlobalChannel(in image: ModularImage) -> Int {
            for i in image.nbMetaChannels..<image.channels.count {
                let ch = image.channels[i]
                if ch.width > groupDim || ch.height > groupDim {
                    return i
                }
            }
            return image.channels.count
        }

        private func isGlobalSectionChannel(_ index: Int, in image: ModularImage) -> Bool {
            index < firstNonGlobalChannel(in: image)
        }

        private func isDCGroupChannel(_ index: Int, in image: ModularImage) -> Bool {
            if isGlobalSectionChannel(index, in: image) { return false }
            let ch = image.channels[index]
            return ch.hshift >= 3 && ch.vshift >= 3
        }

        private func isACGroupChannel(_ index: Int, in image: ModularImage) -> Bool {
            if isGlobalSectionChannel(index, in: image) { return false }
            let ch = image.channels[index]
            return ch.hshift < 3 || ch.vshift < 3
        }

        private struct GroupChannelSlice: Sendable {
            let parentChannelIndex: Int
            let x0: Int
            let y0: Int
            let width: Int
            let height: Int
            let hshift: Int
            let vshift: Int
        }

        private func groupSlices(
            for image: ModularImage,
            gx: Int,
            gy: Int,
            baseDim: Int,
            filter: (Int, ModularImage) -> Bool
        ) -> [GroupChannelSlice] {
            var slices: [GroupChannelSlice] = []
            for i in image.channels.indices where filter(i, image) {
                let ch = image.channels[i]
                let hs = max(0, ch.hshift)
                let vs = max(0, ch.vshift)
                let x0 = (gx * baseDim) >> hs
                let y0 = (gy * baseDim) >> vs
                let x1 = min(ch.width, ((gx + 1) * baseDim) >> hs)
                let y1 = min(ch.height, ((gy + 1) * baseDim) >> vs)
                if x0 < x1 && y0 < y1 {
                    slices.append(GroupChannelSlice(
                        parentChannelIndex: i,
                        x0: x0,
                        y0: y0,
                        width: x1 - x0,
                        height: y1 - y0,
                        hshift: ch.hshift,
                        vshift: ch.vshift
                    ))
                }
            }
            return slices
        }

        private func decodeGroupSubstreamToPlanes(
            sectionIndex: Int,
            groupId: Int32,
            slices: [GroupChannelSlice],
            sampleMaximum: Int32?,
            globalRCTTransforms: [ModularTransform] = [],
            canFuseRCT6InWrite: Bool = false
        ) throws -> (channels: [ModularChannel], fusedRCT6: Bool) {
            var reader = try sectionReader(sectionIndex)
            if slices.isEmpty {
                try reader.expectZeroPadding()
                guard reader.isExhausted else {
                    throw ScalarModularError.invalidInput("Unexpected bytes in empty Modular group section")
                }
                return ([], false)
            }
            let groupHeader = try GroupHeader.read(from: &reader)
            let pixelCount = slices.reduce(0) { $0 + $1.width * $1.height }
            let entropy = try selectEntropy(
                header: groupHeader,
                from: &reader,
                pixelCount: pixelCount
            )
            try budget.reserveWorkspace(
                ScalarOperationBudget.product(entropy.codebook.ansCounts.count, 64 * 1024)
            )
            try ModularImage.admitDescriptors(slices.count, budget: budget)
            var groupImage = try ModularImage(
                channels: slices.map {
                    try ModularChannel(
                        width: $0.width,
                        height: $0.height,
                        hshift: $0.hshift,
                        vshift: $0.vshift
                    )
                }
            )
            let localTransforms = try metaApplyTransforms(
                image: &groupImage,
                transforms: groupHeader.transforms,
                budget: budget
            )
            let maxWidth = groupImage.channels.map(\.width).max() ?? 0
            var stream = TokenStreamReader(
                header: entropy.header,
                codebook: entropy.codebook,
                distanceMultiplier: maxWidth
            )
            let checkMax: Int32? = (localTransforms.isEmpty && globalRCTTransforms.isEmpty) ? sampleMaximum : nil
            for i in groupImage.channels.indices {
                try groupImage.channels[i].allocatePixels(budget: budget)
                try decodeChannelIntoArray(
                    channel: &groupImage.channels[i],
                    staticChannel: Int32(i),
                    groupId: groupId,
                    tree: entropy.tree,
                    stream: &stream,
                    from: &reader,
                    wpHeader: groupHeader.wpHeader,
                    sampleMaximum: checkMax
                )
            }
            try stream.finish(from: &reader)
            try reader.expectZeroPadding()
            guard reader.isExhausted else {
                throw ScalarModularError.invalidInput("Unexpected trailing bytes in Modular group section")
            }
            let isSingleRCT6: Bool = {
                if localTransforms.count == 1 && globalRCTTransforms.isEmpty {
                    let t = localTransforms[0]
                    return t.id == .rct && t.beginC == 0 && t.rctType == 6
                }
                if localTransforms.isEmpty && globalRCTTransforms.count == 1 {
                    let t = globalRCTTransforms[0]
                    return t.id == .rct && t.beginC == 0 && t.rctType == 6
                }
                return false
            }()
            if canFuseRCT6InWrite && isSingleRCT6 && groupImage.nbMetaChannels == 0 && groupImage.channels.count == slices.count {
                return (groupImage.channels, true)
            }
            if !localTransforms.isEmpty {
                try applyInverseTransforms(
                    image: &groupImage,
                    transforms: localTransforms,
                    bitDepth: bitsPerSample,
                    budget: budget
                )
            }
            guard groupImage.channels.count == slices.count else {
                throw ScalarModularError.invalidInput("Group channel count mismatch after inverse transforms")
            }
            if !globalRCTTransforms.isEmpty {
                try applyInverseTransforms(
                    image: &groupImage,
                    transforms: globalRCTTransforms,
                    bitDepth: bitsPerSample,
                    budget: budget
                )
            }
            return (groupImage.channels, false)
        }

        private func canFuseGroupSlicesRCT6(
            slices: [GroupChannelSlice],
            layouts: [ModularChannelLayout]
        ) -> Bool {
            if slices.count == 3 && layouts.count == 3
                && slices[0].parentChannelIndex == 0 && slices[1].parentChannelIndex == 1 && slices[2].parentChannelIndex == 2
                && slices[0].x0 == slices[1].x0 && slices[1].x0 == slices[2].x0
                && slices[0].y0 == slices[1].y0 && slices[1].y0 == slices[2].y0
                && slices[0].width == slices[1].width && slices[1].width == slices[2].width
                && slices[0].height == slices[1].height && slices[1].height == slices[2].height {
                let l0 = layouts[0], l1 = layouts[1], l2 = layouts[2]
                if l0.storageBits == 8 && l1.storageBits == 8 && l2.storageBits == 8
                    && l0.pixelStride == 3 && l1.pixelStride == 3 && l2.pixelStride == 3
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes
                    && l0.offset == 0 && l1.offset == 1 && l2.offset == 2 {
                    return true
                }
                if l0.storageBits == 16 && l1.storageBits == 16 && l2.storageBits == 16
                    && l0.littleEndian && l1.littleEndian && l2.littleEndian
                    && l0.pixelStride == 6 && l1.pixelStride == 6 && l2.pixelStride == 6
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes
                    && l0.offset == 0 && l1.offset == 2 && l2.offset == 4 {
                    return true
                }
            } else if slices.count == 4 && layouts.count == 4
                && slices[0].parentChannelIndex == 0 && slices[1].parentChannelIndex == 1
                && slices[2].parentChannelIndex == 2 && slices[3].parentChannelIndex == 3
                && slices[0].x0 == slices[1].x0 && slices[1].x0 == slices[2].x0 && slices[2].x0 == slices[3].x0
                && slices[0].y0 == slices[1].y0 && slices[1].y0 == slices[2].y0 && slices[2].y0 == slices[3].y0
                && slices[0].width == slices[1].width && slices[1].width == slices[2].width && slices[2].width == slices[3].width
                && slices[0].height == slices[1].height && slices[1].height == slices[2].height && slices[2].height == slices[3].height {
                let l0 = layouts[0], l1 = layouts[1], l2 = layouts[2], l3 = layouts[3]
                if l0.storageBits == 8 && l1.storageBits == 8 && l2.storageBits == 8 && l3.storageBits == 8
                    && l0.pixelStride == 4 && l1.pixelStride == 4 && l2.pixelStride == 4 && l3.pixelStride == 4
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes && l2.rowBytes == l3.rowBytes
                    && l0.offset == 0 && l1.offset == 1 && l2.offset == 2 && l3.offset == 3 {
                    return true
                }
                if l0.storageBits == 16 && l1.storageBits == 16 && l2.storageBits == 16 && l3.storageBits == 16
                    && l0.littleEndian && l1.littleEndian && l2.littleEndian && l3.littleEndian
                    && l0.pixelStride == 8 && l1.pixelStride == 8 && l2.pixelStride == 8 && l3.pixelStride == 8
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes && l2.rowBytes == l3.rowBytes
                    && l0.offset == 0 && l1.offset == 2 && l2.offset == 4 && l3.offset == 6 {
                    return true
                }
            }
            return false
        }

        private func writeGroupSlicesToLayouts(
            _ channels: [ModularChannel],
            slices: [GroupChannelSlice],
            into bytes: UnsafeMutableRawBufferPointer,
            layouts: [ModularChannelLayout],
            maxU: UInt32,
            fusedRCT6: Bool = false
        ) throws {
            if slices.count == 3 && layouts.count == 3
                && slices[0].parentChannelIndex == 0 && slices[1].parentChannelIndex == 1 && slices[2].parentChannelIndex == 2
                && slices[0].x0 == slices[1].x0 && slices[1].x0 == slices[2].x0
                && slices[0].y0 == slices[1].y0 && slices[1].y0 == slices[2].y0
                && slices[0].width == slices[1].width && slices[1].width == slices[2].width
                && slices[0].height == slices[1].height && slices[1].height == slices[2].height {
                let l0 = layouts[0], l1 = layouts[1], l2 = layouts[2]
                let rectX = slices[0].x0, rectY = slices[0].y0
                let rectW = slices[0].width, rectH = slices[0].height
                let rowStep = max(1, 4096 / max(1, rectW))
                if l0.storageBits == 8 && l1.storageBits == 8 && l2.storageBits == 8
                    && l0.pixelStride == 3 && l1.pixelStride == 3 && l2.pixelStride == 3
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes
                    && l0.offset == 0 && l1.offset == 1 && l2.offset == 2 {
                    let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let rowBytes = l0.rowBytes
                    try channels[0].pixels.withUnsafeBufferPointer { b0 in
                        try channels[1].pixels.withUnsafeBufferPointer { b1 in
                            try channels[2].pixels.withUnsafeBufferPointer { b2 in
                                guard let p0 = b0.baseAddress, let p1 = b1.baseAddress, let p2 = b2.baseAddress else { return }
                                if fusedRCT6 {
                                    for ry in 0..<rectH {
                                        if ry % rowStep == 0 { try budget.checkpoint() }
                                        let srcRow = ry &* rectW
                                        var dstPos = (rectY &+ ry) &* rowBytes &+ rectX &* 3
                                        for rx in 0..<rectW {
                                            let i = srcRow &+ rx
                                            let yv = p0[i], co = p1[i], cg = p2[i]
                                            let t = yv &- (cg >> 1)
                                            let g = cg &+ t
                                            let b = t &- (co >> 1)
                                            let r = b &+ co
                                            guard (UInt32(bitPattern: r) | UInt32(bitPattern: g) | UInt32(bitPattern: b)) <= maxU else {
                                                throw ScalarModularError.invalidInput("Sample outside declared precision")
                                            }
                                            rawBase[dstPos] = UInt8(truncatingIfNeeded: r)
                                            rawBase[dstPos &+ 1] = UInt8(truncatingIfNeeded: g)
                                            rawBase[dstPos &+ 2] = UInt8(truncatingIfNeeded: b)
                                            dstPos &+= 3
                                        }
                                    }
                                } else {
                                    for ry in 0..<rectH {
                                        if ry % rowStep == 0 { try budget.checkpoint() }
                                        let srcRow = ry &* rectW
                                        var dstPos = (rectY &+ ry) &* rowBytes &+ rectX &* 3
                                        for rx in 0..<rectW {
                                            let i = srcRow &+ rx
                                            let v0 = p0[i], v1 = p1[i], v2 = p2[i]
                                            guard (UInt32(bitPattern: v0) | UInt32(bitPattern: v1) | UInt32(bitPattern: v2)) <= maxU else {
                                                throw ScalarModularError.invalidInput("Sample outside declared precision")
                                            }
                                            rawBase[dstPos] = UInt8(truncatingIfNeeded: v0)
                                            rawBase[dstPos &+ 1] = UInt8(truncatingIfNeeded: v1)
                                            rawBase[dstPos &+ 2] = UInt8(truncatingIfNeeded: v2)
                                            dstPos &+= 3
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return
                }
                if l0.storageBits == 16 && l1.storageBits == 16 && l2.storageBits == 16
                    && l0.littleEndian && l1.littleEndian && l2.littleEndian
                    && l0.pixelStride == 6 && l1.pixelStride == 6 && l2.pixelStride == 6
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes
                    && l0.offset == 0 && l1.offset == 2 && l2.offset == 4 {
                    let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let rowBytes = l0.rowBytes
                    try channels[0].pixels.withUnsafeBufferPointer { b0 in
                        try channels[1].pixels.withUnsafeBufferPointer { b1 in
                            try channels[2].pixels.withUnsafeBufferPointer { b2 in
                                guard let p0 = b0.baseAddress, let p1 = b1.baseAddress, let p2 = b2.baseAddress else { return }
                                if fusedRCT6 {
                                    for ry in 0..<rectH {
                                        if ry % rowStep == 0 { try budget.checkpoint() }
                                        let srcRow = ry &* rectW
                                        var dstPos = (rectY &+ ry) &* rowBytes &+ rectX &* 6
                                        for rx in 0..<rectW {
                                            let i = srcRow &+ rx
                                            let yv = p0[i], co = p1[i], cg = p2[i]
                                            let t = yv &- (cg >> 1)
                                            let g = cg &+ t
                                            let b = t &- (co >> 1)
                                            let r = b &+ co
                                            guard (UInt32(bitPattern: r) | UInt32(bitPattern: g) | UInt32(bitPattern: b)) <= maxU else {
                                                throw ScalarModularError.invalidInput("Sample outside declared precision")
                                            }
                                            rawBase[dstPos] = UInt8(truncatingIfNeeded: r)
                                            rawBase[dstPos &+ 1] = UInt8(truncatingIfNeeded: r >> 8)
                                            rawBase[dstPos &+ 2] = UInt8(truncatingIfNeeded: g)
                                            rawBase[dstPos &+ 3] = UInt8(truncatingIfNeeded: g >> 8)
                                            rawBase[dstPos &+ 4] = UInt8(truncatingIfNeeded: b)
                                            rawBase[dstPos &+ 5] = UInt8(truncatingIfNeeded: b >> 8)
                                            dstPos &+= 6
                                        }
                                    }
                                } else {
                                    for ry in 0..<rectH {
                                        if ry % rowStep == 0 { try budget.checkpoint() }
                                        let srcRow = ry &* rectW
                                        var dstPos = (rectY &+ ry) &* rowBytes &+ rectX &* 6
                                        for rx in 0..<rectW {
                                            let i = srcRow &+ rx
                                            let v0 = p0[i], v1 = p1[i], v2 = p2[i]
                                            guard (UInt32(bitPattern: v0) | UInt32(bitPattern: v1) | UInt32(bitPattern: v2)) <= maxU else {
                                                throw ScalarModularError.invalidInput("Sample outside declared precision")
                                            }
                                            rawBase[dstPos] = UInt8(truncatingIfNeeded: v0)
                                            rawBase[dstPos &+ 1] = UInt8(truncatingIfNeeded: v0 >> 8)
                                            rawBase[dstPos &+ 2] = UInt8(truncatingIfNeeded: v1)
                                            rawBase[dstPos &+ 3] = UInt8(truncatingIfNeeded: v1 >> 8)
                                            rawBase[dstPos &+ 4] = UInt8(truncatingIfNeeded: v2)
                                            rawBase[dstPos &+ 5] = UInt8(truncatingIfNeeded: v2 >> 8)
                                            dstPos &+= 6
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return
                }
            } else if slices.count == 4 && layouts.count == 4
                && slices[0].parentChannelIndex == 0 && slices[1].parentChannelIndex == 1
                && slices[2].parentChannelIndex == 2 && slices[3].parentChannelIndex == 3
                && slices[0].x0 == slices[1].x0 && slices[1].x0 == slices[2].x0 && slices[2].x0 == slices[3].x0
                && slices[0].y0 == slices[1].y0 && slices[1].y0 == slices[2].y0 && slices[2].y0 == slices[3].y0
                && slices[0].width == slices[1].width && slices[1].width == slices[2].width && slices[2].width == slices[3].width
                && slices[0].height == slices[1].height && slices[1].height == slices[2].height && slices[2].height == slices[3].height {
                let l0 = layouts[0], l1 = layouts[1], l2 = layouts[2], l3 = layouts[3]
                let rectX = slices[0].x0, rectY = slices[0].y0
                let rectW = slices[0].width, rectH = slices[0].height
                let rowStep = max(1, 4096 / max(1, rectW))
                if l0.storageBits == 8 && l1.storageBits == 8 && l2.storageBits == 8 && l3.storageBits == 8
                    && l0.pixelStride == 4 && l1.pixelStride == 4 && l2.pixelStride == 4 && l3.pixelStride == 4
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes && l2.rowBytes == l3.rowBytes
                    && l0.offset == 0 && l1.offset == 1 && l2.offset == 2 && l3.offset == 3 {
                    let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let rowBytes = l0.rowBytes
                    try channels[0].pixels.withUnsafeBufferPointer { b0 in
                        try channels[1].pixels.withUnsafeBufferPointer { b1 in
                            try channels[2].pixels.withUnsafeBufferPointer { b2 in
                                try channels[3].pixels.withUnsafeBufferPointer { b3 in
                                    guard let p0 = b0.baseAddress, let p1 = b1.baseAddress, let p2 = b2.baseAddress, let p3 = b3.baseAddress else { return }
                                    if fusedRCT6 {
                                        for ry in 0..<rectH {
                                            if ry % rowStep == 0 { try budget.checkpoint() }
                                            let srcRow = ry &* rectW
                                            var dstPos = (rectY &+ ry) &* rowBytes &+ rectX &* 4
                                            for rx in 0..<rectW {
                                                let i = srcRow &+ rx
                                                let yv = p0[i], co = p1[i], cg = p2[i], v3 = p3[i]
                                                let t = yv &- (cg >> 1)
                                                let g = cg &+ t
                                                let b = t &- (co >> 1)
                                                let r = b &+ co
                                                guard (UInt32(bitPattern: r) | UInt32(bitPattern: g) | UInt32(bitPattern: b) | UInt32(bitPattern: v3)) <= maxU else {
                                                    throw ScalarModularError.invalidInput("Sample outside declared precision")
                                                }
                                                rawBase[dstPos] = UInt8(truncatingIfNeeded: r)
                                                rawBase[dstPos &+ 1] = UInt8(truncatingIfNeeded: g)
                                                rawBase[dstPos &+ 2] = UInt8(truncatingIfNeeded: b)
                                                rawBase[dstPos &+ 3] = UInt8(truncatingIfNeeded: v3)
                                                dstPos &+= 4
                                            }
                                        }
                                    } else {
                                        for ry in 0..<rectH {
                                            if ry % rowStep == 0 { try budget.checkpoint() }
                                            let srcRow = ry &* rectW
                                            var dstPos = (rectY &+ ry) &* rowBytes &+ rectX &* 4
                                            for rx in 0..<rectW {
                                                let i = srcRow &+ rx
                                                let v0 = p0[i], v1 = p1[i], v2 = p2[i], v3 = p3[i]
                                                guard (UInt32(bitPattern: v0) | UInt32(bitPattern: v1) | UInt32(bitPattern: v2) | UInt32(bitPattern: v3)) <= maxU else {
                                                    throw ScalarModularError.invalidInput("Sample outside declared precision")
                                                }
                                                rawBase[dstPos] = UInt8(truncatingIfNeeded: v0)
                                                rawBase[dstPos &+ 1] = UInt8(truncatingIfNeeded: v1)
                                                rawBase[dstPos &+ 2] = UInt8(truncatingIfNeeded: v2)
                                                rawBase[dstPos &+ 3] = UInt8(truncatingIfNeeded: v3)
                                                dstPos &+= 4
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return
                }
                if l0.storageBits == 16 && l1.storageBits == 16 && l2.storageBits == 16 && l3.storageBits == 16
                    && l0.littleEndian && l1.littleEndian && l2.littleEndian && l3.littleEndian
                    && l0.pixelStride == 8 && l1.pixelStride == 8 && l2.pixelStride == 8 && l3.pixelStride == 8
                    && l0.rowBytes == l1.rowBytes && l1.rowBytes == l2.rowBytes && l2.rowBytes == l3.rowBytes
                    && l0.offset == 0 && l1.offset == 2 && l2.offset == 4 && l3.offset == 6 {
                    let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let rowBytes = l0.rowBytes
                    try channels[0].pixels.withUnsafeBufferPointer { b0 in
                        try channels[1].pixels.withUnsafeBufferPointer { b1 in
                            try channels[2].pixels.withUnsafeBufferPointer { b2 in
                                try channels[3].pixels.withUnsafeBufferPointer { b3 in
                                    guard let p0 = b0.baseAddress, let p1 = b1.baseAddress, let p2 = b2.baseAddress, let p3 = b3.baseAddress else { return }
                                    if fusedRCT6 {
                                        for ry in 0..<rectH {
                                            if ry % rowStep == 0 { try budget.checkpoint() }
                                            let srcRow = ry &* rectW
                                            var dstPos = (rectY &+ ry) &* rowBytes &+ rectX &* 8
                                            for rx in 0..<rectW {
                                                let i = srcRow &+ rx
                                                let yv = p0[i], co = p1[i], cg = p2[i], v3 = p3[i]
                                                let t = yv &- (cg >> 1)
                                                let g = cg &+ t
                                                let b = t &- (co >> 1)
                                                let r = b &+ co
                                                guard (UInt32(bitPattern: r) | UInt32(bitPattern: g) | UInt32(bitPattern: b) | UInt32(bitPattern: v3)) <= maxU else {
                                                    throw ScalarModularError.invalidInput("Sample outside declared precision")
                                                }
                                                rawBase[dstPos] = UInt8(truncatingIfNeeded: r)
                                                rawBase[dstPos &+ 1] = UInt8(truncatingIfNeeded: r >> 8)
                                                rawBase[dstPos &+ 2] = UInt8(truncatingIfNeeded: g)
                                                rawBase[dstPos &+ 3] = UInt8(truncatingIfNeeded: g >> 8)
                                                rawBase[dstPos &+ 4] = UInt8(truncatingIfNeeded: b)
                                                rawBase[dstPos &+ 5] = UInt8(truncatingIfNeeded: b >> 8)
                                                rawBase[dstPos &+ 6] = UInt8(truncatingIfNeeded: v3)
                                                rawBase[dstPos &+ 7] = UInt8(truncatingIfNeeded: v3 >> 8)
                                                dstPos &+= 8
                                            }
                                        }
                                    } else {
                                        for ry in 0..<rectH {
                                            if ry % rowStep == 0 { try budget.checkpoint() }
                                            let srcRow = ry &* rectW
                                            var dstPos = (rectY &+ ry) &* rowBytes &+ rectX &* 8
                                            for rx in 0..<rectW {
                                                let i = srcRow &+ rx
                                                let v0 = p0[i], v1 = p1[i], v2 = p2[i], v3 = p3[i]
                                                guard (UInt32(bitPattern: v0) | UInt32(bitPattern: v1) | UInt32(bitPattern: v2) | UInt32(bitPattern: v3)) <= maxU else {
                                                    throw ScalarModularError.invalidInput("Sample outside declared precision")
                                                }
                                                rawBase[dstPos] = UInt8(truncatingIfNeeded: v0)
                                                rawBase[dstPos &+ 1] = UInt8(truncatingIfNeeded: v0 >> 8)
                                                rawBase[dstPos &+ 2] = UInt8(truncatingIfNeeded: v1)
                                                rawBase[dstPos &+ 3] = UInt8(truncatingIfNeeded: v1 >> 8)
                                                rawBase[dstPos &+ 4] = UInt8(truncatingIfNeeded: v2)
                                                rawBase[dstPos &+ 5] = UInt8(truncatingIfNeeded: v2 >> 8)
                                                rawBase[dstPos &+ 6] = UInt8(truncatingIfNeeded: v3)
                                                rawBase[dstPos &+ 7] = UInt8(truncatingIfNeeded: v3 >> 8)
                                                dstPos &+= 8
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return
                }
            }
            for (i, slice) in slices.enumerated() {
                try writeRectangleToLayout(
                    source: channels[i].pixels,
                    rectX: slice.x0,
                    rectY: slice.y0,
                    rectW: slice.width,
                    rectH: slice.height,
                    into: bytes,
                    layout: layouts[slice.parentChannelIndex],
                    maxU: maxU
                )
            }
        }

        private func copySlice(
            _ source: ModularChannel,
            slice: GroupChannelSlice,
            into destination: inout ModularChannel
        ) throws {
            guard source.width == slice.width,
                  source.height == slice.height,
                  source.pixels.count == source.sampleCount,
                  destination.pixels.count == destination.sampleCount else {
                throw ScalarModularError.invalidInput("Invalid group slice geometry")
            }
            let dstStride = destination.width
            let srcStride = slice.width
            let rowStep = max(1, 4096 / max(1, srcStride))
            try source.pixels.withUnsafeBufferPointer { srcBuf in
                try destination.pixels.withUnsafeMutableBufferPointer { dstBuf in
                    guard let src = srcBuf.baseAddress, let dst = dstBuf.baseAddress else { return }
                    for ry in 0..<slice.height {
                        if ry % rowStep == 0 { try budget.checkpoint() }
                        let srcRow = ry * srcStride
                        let dstRow = (slice.y0 + ry) * dstStride + slice.x0
                        (dst + dstRow).update(from: src + srcRow, count: slice.width)
                    }
                }
            }
        }

        private func decodeMultiSection(
            into bytes: UnsafeMutableRawBufferPointer,
            layouts: [ModularChannelLayout],
            sampleMax: Int32
        ) throws {
            let numDcGroups = dcGroupsX * dcGroupsY
            let numGroups = groupsX * groupsY
            let canApplyGlobalRCTPerGroup = !globalTransforms.isEmpty
                && globalTransforms.allSatisfy({ $0.id == .rct })
                && initialTransformedImage.nbMetaChannels == 0
                && initialTransformedImage.channels.count == channelsCount
                && initialTransformedImage.channels.allSatisfy({
                    $0.width == width && $0.height == height && $0.hshift == 0 && $0.vshift == 0
                })

            // Fast zero-full-frame-plane path when there are no global transforms (or only pixel-wise global RCT) and a single pass:
            if (globalTransforms.isEmpty || canApplyGlobalRCTPerGroup) && passes.numPasses == 1 {
                var sec0Reader = sec0ReaderAfterHeader
                let sec0Entropy = try selectEntropy(
                    header: globalGroupHeader,
                    from: &sec0Reader,
                    pixelCount: width * height
                )
                try budget.reserveWorkspace(
                    ScalarOperationBudget.product(sec0Entropy.codebook.ansCounts.count, 64 * 1024)
                )
                if !sec0Entropy.header.usePrefixCode {
                    if let err = sec0Entropy.codebook.prebuiltANSError {
                        throw TokenStreamReaderError.alias(err)
                    }
                    let finalState = try sec0Reader.read(bits: 32)
                    guard finalState == ANSConstants.initialState else {
                        throw TokenStreamReaderError.ansFinalStateMismatch(got: finalState)
                    }
                }
                try sec0Reader.expectZeroPadding()
                guard sec0Reader.isExhausted else {
                    throw ScalarModularError.invalidInput("Unexpected trailing bytes in DC global section")
                }

                // Verify DC group sections and HfGlobal section are empty
                for dcIdx in 0..<numDcGroups {
                    var dcReader = try sectionReader(1 + dcIdx)
                    try dcReader.expectZeroPadding()
                    guard dcReader.isExhausted else {
                        throw ScalarModularError.invalidInput("Unexpected bytes in Modular DC group section")
                    }
                }
                var hfGlobalReader = try sectionReader(1 + numDcGroups)
                try hfGlobalReader.expectZeroPadding()
                guard hfGlobalReader.isExhausted else {
                    throw ScalarModularError.invalidInput("Unexpected bytes in Modular HF global section")
                }

                let firstACSection = 2 + numDcGroups
                let maxU = UInt32(bitPattern: sampleMax)

                if budget.maximumWorkers == 1 {
                    for groupIndex in 0..<numGroups {
                        let gx = groupIndex % groupsX
                        let gy = groupIndex / groupsX
                        let slices = groupSlices(
                            for: initialTransformedImage,
                            gx: gx,
                            gy: gy,
                            baseDim: groupDim,
                            filter: isACGroupChannel
                        )
                        var reader = try sectionReader(firstACSection + groupIndex)
                        let groupHeader = try GroupHeader.read(from: &reader)
                        let pixelCount = slices.reduce(0) { $0 + $1.width * $1.height }
                        let entropy = try selectEntropy(
                            header: groupHeader,
                            from: &reader,
                            pixelCount: pixelCount
                        )
                        try budget.reserveWorkspace(
                            ScalarOperationBudget.product(entropy.codebook.ansCounts.count, 64 * 1024)
                        )
                        let groupId = Int32(1 + 3 * numDcGroups + 17 + groupIndex)

                        if groupHeader.transforms.isEmpty && globalTransforms.isEmpty {
                            let maxW = slices.map(\.width).max() ?? 0
                            var stream = TokenStreamReader(
                                header: entropy.header,
                                codebook: entropy.codebook,
                                distanceMultiplier: maxW
                            )
                            for (i, slice) in slices.enumerated() {
                                let subLayout = try layouts[slice.parentChannelIndex].rectangle(
                                    x: slice.x0,
                                    y: slice.y0,
                                    width: slice.width,
                                    height: slice.height
                                )
                                try decodeChannelIntoLayout(
                                    bytes: bytes,
                                    layout: subLayout,
                                    staticChannel: Int32(i),
                                    groupId: groupId,
                                    tree: entropy.tree,
                                    stream: &stream,
                                    from: &reader,
                                    wpHeader: groupHeader.wpHeader,
                                    sampleMaximum: sampleMax
                                )
                            }
                            try stream.finish(from: &reader)
                            try reader.expectZeroPadding()
                            guard reader.isExhausted else {
                                throw ScalarModularError.invalidInput("Unexpected trailing bytes in Modular group section")
                            }
                        } else {
                            let canFuse = canFuseGroupSlicesRCT6(slices: slices, layouts: layouts)
                            let (channels, fusedRCT6) = try decodeGroupSubstreamToPlanes(
                                sectionIndex: firstACSection + groupIndex,
                                groupId: groupId,
                                slices: slices,
                                sampleMaximum: sampleMax,
                                globalRCTTransforms: globalTransforms,
                                canFuseRCT6InWrite: canFuse
                            )
                            try writeGroupSlicesToLayouts(
                                channels,
                                slices: slices,
                                into: bytes,
                                layouts: layouts,
                                maxU: maxU,
                                fusedRCT6: fusedRCT6
                            )
                        }
                    }
                } else {
                    nonisolated(unsafe) let sharedBytes = bytes
                    var baseGroup = 0
                    while baseGroup < numGroups {
                        let batchCount = min(budget.maximumWorkers, numGroups - baseGroup)
                        let currentBase = baseGroup
                        _ = try modularDecodeBatch(
                            count: batchCount,
                            budget: budget
                        ) { (offset: Int) -> Void in
                            let groupIndex = currentBase + offset
                            let gx = groupIndex % groupsX
                            let gy = groupIndex / groupsX
                            let slices = groupSlices(
                                for: initialTransformedImage,
                                gx: gx,
                                gy: gy,
                                baseDim: groupDim,
                                filter: isACGroupChannel
                            )
                            let secIndex = firstACSection + groupIndex
                            let gId = Int32(1 + 3 * numDcGroups + 17 + groupIndex)
                            var reader = try sectionReader(secIndex)
                            let groupHeader = try GroupHeader.read(from: &reader)
                            if groupHeader.transforms.isEmpty && globalTransforms.isEmpty {
                                let pixelCount = slices.reduce(0) { $0 + $1.width * $1.height }
                                let entropy = try selectEntropy(
                                    header: groupHeader,
                                    from: &reader,
                                    pixelCount: pixelCount
                                )
                                try budget.reserveWorkspace(
                                    ScalarOperationBudget.product(entropy.codebook.ansCounts.count, 64 * 1024)
                                )
                                let maxW = slices.map(\.width).max() ?? 0
                                var stream = TokenStreamReader(
                                    header: entropy.header,
                                    codebook: entropy.codebook,
                                    distanceMultiplier: maxW
                                )
                                for (i, slice) in slices.enumerated() {
                                    ScalarStorageAudit.current?.workingPlane(
                                        slice.width * slice.height * MemoryLayout<Int32>.stride
                                    )
                                    let subLayout = try layouts[slice.parentChannelIndex].rectangle(
                                        x: slice.x0,
                                        y: slice.y0,
                                        width: slice.width,
                                        height: slice.height
                                    )
                                    try decodeChannelIntoLayout(
                                        bytes: sharedBytes,
                                        layout: subLayout,
                                        staticChannel: Int32(i),
                                        groupId: gId,
                                        tree: entropy.tree,
                                        stream: &stream,
                                        from: &reader,
                                        wpHeader: groupHeader.wpHeader,
                                        sampleMaximum: sampleMax
                                    )
                                }
                                try stream.finish(from: &reader)
                                try reader.expectZeroPadding()
                                guard reader.isExhausted else {
                                    throw ScalarModularError.invalidInput("Unexpected trailing bytes in Modular group section")
                                }
                            } else {
                                let canFuse = canFuseGroupSlicesRCT6(slices: slices, layouts: layouts)
                                let (planes, fusedRCT6) = try decodeGroupSubstreamToPlanes(
                                    sectionIndex: secIndex,
                                    groupId: gId,
                                    slices: slices,
                                    sampleMaximum: sampleMax,
                                    globalRCTTransforms: globalTransforms,
                                    canFuseRCT6InWrite: canFuse
                                )
                                try writeGroupSlicesToLayouts(
                                    planes,
                                    slices: slices,
                                    into: sharedBytes,
                                    layouts: layouts,
                                    maxU: maxU,
                                    fusedRCT6: fusedRCT6
                                )
                            }
                        }
                        baseGroup += batchCount
                    }
                }
                return
            }

            // General multi-section path with global transforms (e.g., global RCT, Palette, or Squeeze):
            let working = try decodeMultiSectionToImage(sampleMax: sampleMax, validateRange: false)
            try writePlanesToLayouts(
                working.channels,
                into: bytes,
                layouts: layouts,
                sampleMax: sampleMax
            )
        }

        private func decodeMultiSectionToImage(sampleMax: Int32, validateRange: Bool = true) throws -> ModularImage {
            let numDcGroups = dcGroupsX * dcGroupsY
            let numGroups = groupsX * groupsY
            var working = initialTransformedImage

            for i in working.channels.indices {
                try working.channels[i].allocatePixels(budget: budget)
            }

            // 1. Section 0 (LfGlobal)
            var sec0Reader = sec0ReaderAfterHeader
            let sec0Indices = working.channels.indices.filter { isGlobalSectionChannel($0, in: working) }
            let sec0Pixels = sec0Indices.reduce(0) { $0 + working.channels[$1].sampleCount }
            let sec0Entropy = try selectEntropy(
                header: globalGroupHeader,
                from: &sec0Reader,
                pixelCount: max(width * height, sec0Pixels)
            )
            try budget.reserveWorkspace(
                ScalarOperationBudget.product(sec0Entropy.codebook.ansCounts.count, 64 * 1024)
            )
            let sec0MaxW = sec0Indices.map { working.channels[$0].width }.max() ?? 0
            var sec0Stream = TokenStreamReader(
                header: sec0Entropy.header,
                codebook: sec0Entropy.codebook,
                distanceMultiplier: sec0MaxW
            )
            for (staticIdx, channelIdx) in sec0Indices.enumerated() {
                try decodeChannelIntoArray(
                    channel: &working.channels[channelIdx],
                    staticChannel: Int32(staticIdx),
                    groupId: 0,
                    tree: sec0Entropy.tree,
                    stream: &sec0Stream,
                    from: &sec0Reader,
                    wpHeader: globalGroupHeader.wpHeader,
                    sampleMaximum: nil
                )
            }
            try sec0Stream.finish(from: &sec0Reader)
            try sec0Reader.expectZeroPadding()
            guard sec0Reader.isExhausted else {
                throw ScalarModularError.invalidInput("Unexpected trailing bytes in Modular global section")
            }

            // 2. LfGroup sections (1 ..< 1 + numDcGroups)
            for dcIndex in 0..<numDcGroups {
                let dcx = dcIndex % dcGroupsX
                let dcy = dcIndex / dcGroupsX
                let slices = groupSlices(
                    for: working,
                    gx: dcx,
                    gy: dcy,
                    baseDim: dcGroupDim,
                    filter: isDCGroupChannel
                )
                let (planes, _) = try decodeGroupSubstreamToPlanes(
                    sectionIndex: 1 + dcIndex,
                    groupId: Int32(1 + numDcGroups + dcIndex),
                    slices: slices,
                    sampleMaximum: nil
                )
                for (i, slice) in slices.enumerated() {
                    try copySlice(planes[i], slice: slice, into: &working.channels[slice.parentChannelIndex])
                }
            }

            // 3. HfGlobal section (1 + numDcGroups)
            var hfGlobalReader = try sectionReader(1 + numDcGroups)
            try hfGlobalReader.expectZeroPadding()
            guard hfGlobalReader.isExhausted else {
                throw ScalarModularError.invalidInput("Unexpected bytes in Modular HF global section")
            }

            // 4. AC Group sections (2 + numDcGroups ..< 2 + numDcGroups + numPasses * numGroups)
            let firstACSection = 2 + numDcGroups
            let numPasses = Int(passes.numPasses)
            let checkMax: Int32? = (globalTransforms.isEmpty && numPasses == 1) ? sampleMax : nil
            for passIndex in 0..<numPasses {
                let minShift = Int(passes.shifts[passIndex])
                let maxShift = passIndex == 0 ? 3 : Int(passes.shifts[passIndex - 1])
                let passFilter: @Sendable (Int, ModularImage) -> Bool = { idx, img in
                    if isGlobalSectionChannel(idx, in: img) { return false }
                    let ch = img.channels[idx]
                    let shift = min(ch.hshift, ch.vshift)
                    return minShift <= shift && shift < maxShift
                }
                if budget.maximumWorkers == 1 {
                    for groupIndex in 0..<numGroups {
                        let gx = groupIndex % groupsX
                        let gy = groupIndex / groupsX
                        let slices = groupSlices(
                            for: working,
                            gx: gx,
                            gy: gy,
                            baseDim: groupDim,
                            filter: passFilter
                        )
                        let (planes, _) = try decodeGroupSubstreamToPlanes(
                            sectionIndex: firstACSection + passIndex * numGroups + groupIndex,
                            groupId: Int32(1 + 3 * numDcGroups + 17 + passIndex * numGroups + groupIndex),
                            slices: slices,
                            sampleMaximum: checkMax
                        )
                        for (i, slice) in slices.enumerated() {
                            try copySlice(planes[i], slice: slice, into: &working.channels[slice.parentChannelIndex])
                        }
                    }
                } else {
                    let snapshotWorking = working
                    var baseGroup = 0
                    while baseGroup < numGroups {
                        let batchCount = min(budget.maximumWorkers, numGroups - baseGroup)
                        let currentBase = baseGroup
                        let batchResults: [([GroupChannelSlice], [ModularChannel])] = try modularDecodeBatch(
                            count: batchCount,
                            budget: budget
                        ) { (offset: Int) -> ([GroupChannelSlice], [ModularChannel]) in
                            let groupIndex = currentBase + offset
                            let gx = groupIndex % groupsX
                            let gy = groupIndex / groupsX
                            let slices = groupSlices(
                                for: snapshotWorking,
                                gx: gx,
                                gy: gy,
                                baseDim: groupDim,
                                filter: passFilter
                            )
                            let secIndex = firstACSection + passIndex * numGroups + groupIndex
                            let gId = Int32(1 + 3 * numDcGroups + 17 + passIndex * numGroups + groupIndex)
                            let (planes, _) = try decodeGroupSubstreamToPlanes(
                                sectionIndex: secIndex,
                                groupId: gId,
                                slices: slices,
                                sampleMaximum: checkMax
                            )
                            return (slices, planes)
                        }
                        for (slices, planes) in batchResults {
                            for (i, slice) in slices.enumerated() {
                                try copySlice(planes[i], slice: slice, into: &working.channels[slice.parentChannelIndex])
                            }
                        }
                        baseGroup += batchCount
                    }
                }
            }

            if !globalTransforms.isEmpty {
                try applyInverseTransforms(
                    image: &working,
                    transforms: globalTransforms,
                    bitDepth: bitsPerSample,
                    budget: budget
                )
                if validateRange {
                    try validateSamplesInRange(working, sampleMax: sampleMax)
                }
            }
            return working
        }

        private func validateSamplesInRange(_ image: ModularImage, sampleMax: Int32) throws {
            guard image.nbMetaChannels == 0, image.channels.count == channelsCount else {
                throw ScalarModularError.invalidInput("Invalid channel count after Modular inverse transforms")
            }
            let maxU = UInt32(bitPattern: sampleMax)
            for ch in image.channels {
                guard ch.width == width, ch.height == height, ch.pixels.count == ch.sampleCount else {
                    throw ScalarModularError.invalidInput("Invalid channel geometry after Modular inverse transforms")
                }
                try ch.pixels.withUnsafeBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    for i in 0..<buf.count {
                        if (i & 4095) == 0 { try budget.checkpoint() }
                        if UInt32(bitPattern: base[i]) > maxU {
                            throw ScalarModularError.invalidInput("Sample outside declared precision")
                        }
                    }
                }
            }
        }
    }

    package static func prepare(
        _ data: Data,
        budget: ScalarOperationBudget,
        maximumDimension: Int = 16384,
        maximumPixels: Int = 64 * 1024 * 1024,
        maximumNestingDepth: Int = 32,
        maximumICCBytes: Int = 4 * 1024 * 1024,
        maximumMetadataBytes: Int = 16 * 1024 * 1024
    ) throws -> Prepared {
        let header = try PixelFrameHeader.read(
            data,
            budget: budget,
            maximumDimension: maximumDimension,
            maximumPixels: maximumPixels,
            maximumNestingDepth: maximumNestingDepth
        )
        return try prepare(
            header,
            maximumICCBytes: maximumICCBytes,
            maximumMetadataBytes: maximumMetadataBytes
        )
    }

    package static func prepare(
        _ preparedHeader: PixelFrameHeader,
        maximumICCBytes: Int = 4 * 1024 * 1024,
        maximumMetadataBytes: Int = 16 * 1024 * 1024
    ) throws -> Prepared {
        let budget = preparedHeader.budget
        try budget.checkpoint()
        let codestream = preparedHeader.codestream
        let metadata = preparedHeader.metadata
        let width = preparedHeader.width
        let height = preparedHeader.height
        let maximumNestingDepth = preparedHeader.maximumNestingDepth
        var reader = preparedHeader.reader

        let colour = metadata.colorEncoding
        guard !metadata.xybEncoded,
              !metadata.bitDepth.floatingPoint,
              (1...16).contains(metadata.bitDepth.bitsPerSample),
              [.rgb, .grayscale].contains(colour.colorSpace),
              colour.useICC
                  || (colour.whitePoint == .d65
                      && [TransferFunction.srgb, .bt709].contains(colour.transferFunction)
                      && (colour.colorSpace == .grayscale || colour.primaries == .srgb)),
              metadata.orientation == 1,
              metadata.preview == nil,
              metadata.animation == nil,
              metadata.intrinsicSize == nil,
              metadata.intensityTarget == 255,
              metadata.minNits == 0,
              !metadata.relativeToMaxDisplay,
              metadata.linearBelow == 0,
              metadata.extraChannels.count <= 1 else {
            throw ScalarModularError.unsupportedProfile
        }
        for extra in metadata.extraChannels {
            guard extra.type == .alpha,
                  !extra.bitDepth.floatingPoint,
                  extra.bitDepth.bitsPerSample == metadata.bitDepth.bitsPerSample,
                  extra.dimShift == 0,
                  extra.name.isEmpty else {
                throw ScalarModularError.unsupportedProfile
            }
        }
        guard try reader.readBit() else {
            throw ScalarModularError.unsupportedProfile
        }

        let iccProfile: Data?
        if colour.useICC {
            guard maximumICCBytes > 0, maximumMetadataBytes > 0 else {
                throw ScalarModularError.resourceLimit
            }
            do {
                iccProfile = try ICCStream.decode(
                    from: &reader,
                    maximumBytes: min(maximumICCBytes, maximumMetadataBytes, 4 * 1024 * 1024),
                    checkpoint: budget.checkpoint
                )
            } catch JPEGEntropyError.resourceLimit {
                throw ScalarModularError.resourceLimit
            }
            if let profile = iccProfile {
                guard profile.count >= 128,
                      profile.prefix(4).reduce(0, { ($0 << 8) | Int($1) }) == profile.count,
                      profile[36..<40] == Data("acsp".utf8),
                      profile[16..<20] == Data((colour.colorSpace == .grayscale ? "GRAY" : "RGB ").utf8) else {
                    throw ScalarModularError.invalidInput("ICC header does not match the image colour model")
                }
            }
        } else {
            iccProfile = nil
        }

        try reader.expectZeroPadding()
        let frame = try FrameHeader.read(
            from: &reader,
            context: .init(xybEncoded: false, numExtraChannels: metadata.extraChannels.count)
        )
        guard frame.encoding == .modular,
              frame.frameType == .regular,
              frame.isLast,
              frame.flags == 0 || frame.flags == 128,
              frame.colorTransform == .none,
              frame.upsampling == 1,
              frame.extraChannelUpsampling.allSatisfy({ $0 == 1 }),
              (1...11).contains(frame.passes.numPasses),
              frame.passes.numDownsample <= 4,
              !frame.customSizeOrOrigin,
              frame.blendingInfo.mode == .replace,
              frame.extraChannelBlendingInfo.allSatisfy({ $0.mode == .replace }),
              frame.name.isEmpty,
              !frame.loopFilter.gab,
              frame.loopFilter.epfIters == 0 else {
            throw ScalarModularError.unsupportedProfile
        }

        let groupDim = 128 << Int(frame.groupSizeShift)
        let dcGroupDim = groupDim * 8
        let groupsX = (width - 1) / groupDim + 1
        let groupsY = (height - 1) / groupDim + 1
        let dcGroupsX = (width - 1) / dcGroupDim + 1
        let dcGroupsY = (height - 1) / dcGroupDim + 1
        let numGroups = groupsX * groupsY
        let numDcGroups = dcGroupsX * dcGroupsY
        let numEntries = TOC.numEntries(
            numGroups: numGroups,
            numDcGroups: numDcGroups,
            numPasses: Int(frame.passes.numPasses)
        )
        try budget.reserveWorkspace(ScalarOperationBudget.product(numEntries, 128))
        let toc = try TOC.read(from: &reader, numEntries: numEntries)
        let payloadStart = reader.position / 8
        var totalPayload = 0
        for size in toc.entrySizes {
            totalPayload = try ScalarOperationBudget.sum(totalPayload, Int(size))
        }
        guard totalPayload == codestream.count - payloadStart else {
            throw ScalarModularError.invalidInput("Modular section lengths do not match codestream")
        }
        for i in toc.entrySizes.indices {
            guard let offset = Int(exactly: toc.offsets[i]),
                  offset <= totalPayload,
                  Int(toc.entrySizes[i]) <= totalPayload - offset else {
                throw ScalarModularError.invalidInput("Invalid Modular section offset")
            }
        }

        let sec0Offset = Int(toc.offsets[0])
        let sec0Length = Int(toc.entrySizes[0])
        try budget.reserveWorkspace(ScalarOperationBudget.product(sec0Length, 2))
        let sec0Bytes = codestream.subdata(
            in: (payloadStart + sec0Offset)..<(payloadStart + sec0Offset + sec0Length)
        )
        var sec0Reader = BitReader(
            sec0Bytes,
            deadline: budget.deadline,
            maximumNestingDepth: maximumNestingDepth,
            budget: budget
        )
        guard try sec0Reader.readBit() else {
            throw ScalarModularError.unsupportedProfile
        }
        let hasGlobalTree = try sec0Reader.readBit()
        let globalEntropy: EntropyBundle?
        if hasGlobalTree {
            let raw = try ScalarModularDecoder.readTreeAndCodebook(
                from: &sec0Reader,
                pixelCount: width * height
            )
            globalEntropy = (raw.0, raw.1, raw.2)
        } else {
            globalEntropy = nil
        }
        let globalGroupHeader = try GroupHeader.read(from: &sec0Reader)

        let grayscale = (colour.colorSpace == .grayscale)
        let channelsCount = (grayscale ? 1 : 3) + (metadata.extraChannels.isEmpty ? 0 : 1)
        try ModularImage.admitDescriptors(channelsCount, budget: budget)
        var initialImage = try ModularImage(
            channels: (0..<channelsCount).map { _ in
                try ModularChannel(width: width, height: height)
            }
        )
        let globalTransforms = try metaApplyTransforms(
            image: &initialImage,
            transforms: globalGroupHeader.transforms,
            budget: budget
        )
        try budget.checkpoint()

        return Prepared(
            width: width,
            height: height,
            bitsPerSample: Int(metadata.bitDepth.bitsPerSample),
            grayscale: grayscale,
            alphaAssociated: metadata.extraChannels.first?.alphaAssociated,
            iccProfile: iccProfile,
            renderingIntent: colour.renderingIntent,
            transferFunction: colour.transferFunction,
            codestream: codestream,
            toc: toc,
            payloadStart: payloadStart,
            groupDim: groupDim,
            dcGroupDim: dcGroupDim,
            groupsX: groupsX,
            groupsY: groupsY,
            dcGroupsX: dcGroupsX,
            dcGroupsY: dcGroupsY,
            passes: frame.passes,
            channelsCount: channelsCount,
            initialTransformedImage: initialImage,
            globalTransforms: globalTransforms,
            globalGroupHeader: globalGroupHeader,
            globalEntropy: globalEntropy,
            sec0ReaderAfterHeader: sec0Reader,
            budget: budget,
            maximumNestingDepth: maximumNestingDepth
        )
    }

    package static func decode(
        _ data: Data,
        budget: ScalarOperationBudget,
        maximumDimension: Int = 16384,
        maximumPixels: Int = 64 * 1024 * 1024,
        maximumNestingDepth: Int = 32,
        maximumICCBytes: Int = 4 * 1024 * 1024,
        maximumMetadataBytes: Int = 16 * 1024 * 1024
    ) throws -> DecodedFrame {
        let prepared = try prepare(
            data,
            budget: budget,
            maximumDimension: maximumDimension,
            maximumPixels: maximumPixels,
            maximumNestingDepth: maximumNestingDepth,
            maximumICCBytes: maximumICCBytes,
            maximumMetadataBytes: maximumMetadataBytes
        )
        try budget.reservePixels(
            ScalarOperationBudget.product(
                ScalarOperationBudget.product(prepared.width, prepared.height),
                prepared.channelsCount * 2
            )
        )
        let image = try prepared.decodeToImage()
        return DecodedFrame(
            width: prepared.width,
            height: prepared.height,
            bitsPerSample: prepared.bitsPerSample,
            grayscale: prepared.grayscale,
            alphaAssociated: prepared.alphaAssociated,
            iccProfile: prepared.iccProfile,
            renderingIntent: prepared.renderingIntent,
            transferFunction: prepared.transferFunction,
            image: image
        )
    }
}
