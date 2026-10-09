// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Modular/InverseTransforms.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors' algorithms retain BSD-3-Clause terms;
// see Documentation/ThirdParty/libjxl-LICENSE.txt.

/// Invert the expanded chain returned by metaApplyTransforms. Any failure
/// invalidates the working image; callers must never publish partial samples.
/// Only simple palettes are implemented; predicted/delta palettes are rejected.
package func applyInverseTransforms(image: inout ModularImage, transforms: [ModularTransform],
                                    bitDepth: Int, budget: ScalarOperationBudget) throws {
    guard (8...16).contains(bitDepth), transforms.count <= 256,
          image.nbMetaChannels >= 0, image.nbMetaChannels <= image.channels.count,
          image.channels.count <= ModularImage.maximumChannels else {
        throw ModularGeometryError.invalidTransform
    }
    for channel in image.channels { try channel.checkPixels() }
    for t in transforms.reversed() {
        try budget.checkpoint()
        // Admit descriptor-array COW even when unique ownership avoids it.
        try ModularImage.admitDescriptors(image.channels.count, budget: budget)
        switch t.id {
        case .rct:
            let range = try image.checkedRange(begin: t.beginC, count: 3)
            try image.checkEqual(range)
            guard t.rctType < 42 else { throw ModularGeometryError.invalidTransform }
            let start = range.lowerBound
            // Admit possible pixel COW if another owner retained these planes.
            try budget.reserveWorkspace(ScalarOperationBudget.product(image.channels[start].sampleCount, 12))
            var a: [Int32] = [], b: [Int32] = [], c: [Int32] = []
            swap(&a, &image.channels[start].pixels)
            swap(&b, &image.channels[start + 1].pixels)
            swap(&c, &image.channels[start + 2].pixels)
            try SpecRCT.inverse(rctType: t.rctType, channel0: &a, channel1: &b,
                                channel2: &c, checkpoint: budget.checkpoint)
            image.channels[start].pixels = a
            image.channels[start + 1].pixels = b
            image.channels[start + 2].pixels = c
        case .squeeze:
            guard t.squeezes.count <= 256 else { throw ModularGeometryError.invalidTransform }
            for step in t.squeezes.reversed() {
                try budget.checkpoint()
                let range = try image.checkedRange(begin: step.beginC, count: step.numC)
                let offset = step.inPlace ? range.upperBound : image.channels.count - range.count
                guard offset >= range.upperBound, range.count <= image.channels.count - offset else {
                    throw ModularGeometryError.invalidRange
                }
                let isMeta = range.lowerBound < image.nbMetaChannels
                guard !isMeta || (step.inPlace && offset + range.count <= image.nbMetaChannels) else {
                    throw ModularGeometryError.invalidMetaChannels
                }
                for k in 0..<range.count {
                    image.channels[range.lowerBound + k] = try SpecSqueeze.inverse(
                        ll: image.channels[range.lowerBound + k], residual: image.channels[offset + k],
                        horizontal: step.horizontal, budget: budget)
                }
                image.channels.removeSubrange(offset..<(offset + range.count))
                if isMeta { image.nbMetaChannels -= range.count }
            }
        case .palette:
            try inversePalette(image: &image, transform: t, bitDepth: bitDepth, budget: budget)
        }
    }
    try budget.checkpoint()
}

private func inversePalette(image: inout ModularImage, transform t: ModularTransform,
                            bitDepth: Int, budget: ScalarOperationBudget) throws {
    guard t.nbDeltas == 0, t.palettePredictor == 0, t.numC > 0,
          image.nbMetaChannels > 0 else { throw ModularGeometryError.invalidTransform }
    let count = Int(t.numC), indexPosition = Int(t.beginC) + 1
    guard indexPosition < image.channels.count else { throw ModularGeometryError.invalidRange }
    let table = image.channels[0], indices = image.channels[indexPosition]
    guard table.width == Int(t.nbColors), table.height == count,
          table.hshift == -1, table.vshift == -1 else { throw ModularGeometryError.invalidGeometry }
    let finalCount = try ScalarOperationBudget.sum(image.channels.count - 1, count - 1)
    try ModularImage.admitDescriptors(finalCount + 1, budget: budget)
    try ModularImage.admitDescriptors(count, budget: budget)
    // Charge all output planes before allocating any of them. No zero-filled
    // placeholders are allocated in addition to the actual restored planes.
    try budget.reserveWorkspace(ScalarOperationBudget.product(count,
        ScalarOperationBudget.sum(64, ScalarOperationBudget.product(indices.sampleCount, 4))))
    var restored: [ModularChannel] = []
    restored.reserveCapacity(count)
    for c in 0..<count {
        try budget.checkpoint()
        if indices.sampleCount > 0 { ScalarStorageAudit.current?.workingPlane(indices.sampleCount * 4) }
        var values = [Int32](repeating: 0, count: indices.sampleCount)
        for i in values.indices {
            if i & 1023 == 0 { try budget.checkpoint() }
            values[i] = paletteValue(palette: table, index: Int(indices.pixels[i]), c: c,
                                     paletteSize: table.width, bitDepth: bitDepth)
        }
        restored.append(try ModularChannel(width: indices.width, height: indices.height,
            hshift: indices.hshift, vshift: indices.vshift, pixels: values))
    }
    // Compare the index position AFTER insertion of the table. Using beginC
    // here misclassifies the first normal channel as a meta channel.
    let isMeta = indexPosition < image.nbMetaChannels
    image.channels.replaceSubrange(indexPosition..<(indexPosition + 1), with: restored)
    image.channels.removeFirst()
    image.nbMetaChannels += isMeta ? count - 2 : -1
}

private enum ModularDeltaPalette {
    static let values: [(Int32, Int32, Int32)] = [
            (0, 0, 0), (4, 4, 4), (11, 0, 0), (0, 0, -13),
            (0, -12, 0), (-10, -10, -10), (-18, -18, -18), (-27, -27, -27),
            (-18, -18, 0), (0, 0, -32), (-32, 0, 0), (-37, -37, -37),
            (0, -32, -32), (24, 24, 45), (50, 50, 50), (-45, -24, -24),
            (-24, -45, -45), (0, -24, -24), (-34, -34, 0), (-24, 0, -24),
            (-45, -45, -24), (64, 64, 64), (-32, 0, -32), (0, -32, 0),
            (-32, 0, 32), (-24, -45, -24), (45, 24, 45), (24, -24, -45),
            (-45, -24, 24), (80, 80, 80), (64, 0, 0), (0, 0, -64),
            (0, -64, -64), (-24, -24, 45), (96, 96, 96), (64, 64, 0),
            (45, -24, -24), (34, -34, 0), (112, 112, 112), (24, -45, -45),
            (45, 45, -24), (0, -32, 32), (24, -24, 45), (0, 96, 96),
            (45, -24, 24), (24, -45, -24), (-24, -45, 24), (0, -64, 0),
            (96, 0, 0), (128, 128, 128), (64, 0, 64), (144, 144, 144),
            (96, 96, 0), (-36, -36, 36), (45, -24, -45), (45, -45, -24),
            (0, 0, -96), (0, 128, 128), (0, 96, 0), (45, 24, -45),
            (-128, 0, 0), (24, -45, 24), (-45, 24, -45), (64, 0, -64),
            (64, -64, -64), (96, 0, 96), (45, -45, 24), (24, 45, -45),
            (64, 64, -64), (128, 128, 0), (0, 0, -128), (-24, 45, -45)
    ]
}

private func paletteValue(
    palette: ModularChannel, index: Int, c: Int,
    paletteSize: Int, bitDepth: Int
) -> Int32 {
    let kRgbChannels = 3
    let kSmallCube = 4
    let kSmallCubeBits = 2
    let kLargeCube = 5
    let kLargeCubeOffset = kSmallCube * kSmallCube * kSmallCube
    if index < 0 {
        // Delta-palette fallback. 72-entry table, alternating sign.
        if c >= kRgbChannels { return 0 }
        let kDelta = ModularDeltaPalette.values
        var idx2 = -(index + 1)
        idx2 %= 1 + 2 * (kDelta.count - 1)
        let half = (idx2 + 1) >> 1
        let entry = kDelta[half]
        let multiplier: Int32 = (idx2 & 1) == 0 ? -1 : 1
        var result: Int32
        switch c {
        case 0: result = entry.0 &* multiplier
        case 1: result = entry.1 &* multiplier
        default: result = entry.2 &* multiplier
        }
        if bitDepth > 8 {
            result &*= Int32(1 &<< (bitDepth - 8))
        }
        return result
    }
    if index < paletteSize {
        // Direct palette lookup. Palette layout: row c contains the
        // c-th component for each palette entry (libjxl's
        // `palette[c * onerow + index]` with `onerow = palette.w`).
        if c >= palette.height { return 0 }
        let p = palette.pixels[c * palette.width + index]
        return p
    }
    // index >= paletteSize: synthetic cube fall-backs.
    if c >= kRgbChannels { return 0 }
    let smallCubeEnd = paletteSize + kLargeCubeOffset
    if index < smallCubeEnd {
        // Small-cube fall-back.
        let i0 = index - paletteSize
        let i1 = i0 >> (c * kSmallCubeBits)
        let v = i1 % kSmallCube
        // libjxl's Scale<kSmallCube>: (value * ((1<<bitDepth) - 1)) >> 2.
        let scaled = (UInt64(v) * (UInt64(1 << bitDepth) - 1)) >> 2
        return Int32(scaled) &+ Int32(1 &<< max(0, bitDepth - 3))
    }
    // Large-cube fall-back.
    var i0 = index - smallCubeEnd
    switch c {
    case 1: i0 /= kLargeCube
    case 2: i0 /= kLargeCube * kLargeCube
    default: break
    }
    let v = i0 % kLargeCube
    // Scale<kLargeCube - 1>: divide by 4.
    let scaled = (UInt64(v) * (UInt64(1 << bitDepth) - 1)) >> 2
    return Int32(scaled)
}
