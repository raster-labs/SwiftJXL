// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Modular/ModularImage.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors' algorithms retain BSD-3-Clause terms;
// see Documentation/ThirdParty/libjxl-LICENSE.txt.

package enum ModularGeometryError: Error, Sendable {
    case invalidGeometry, invalidPixels, invalidRange, unequalChannels
    case invalidMetaChannels, invalidTransform, populatedGeometry, channelLimit
}

/// Geometry is validated without allocating a pixel plane. Empty residual
/// channels are valid; a nonempty plane must have exactly sampleCount values.
package struct ModularChannel: Sendable, Equatable {
    package let width: Int
    package let height: Int
    package let hshift: Int
    package let vshift: Int
    package let sampleCount: Int
    package var pixels: [Int32]

    package init(width: Int, height: Int, hshift: Int = 0, vshift: Int = 0,
                 pixels: [Int32] = []) throws {
        guard width >= 0, height >= 0, (-1...31).contains(hshift),
              (-1...31).contains(vshift) else { throw ModularGeometryError.invalidGeometry }
        let count = try ScalarOperationBudget.product(width, height)
        _ = try ScalarOperationBudget.product(count, MemoryLayout<Int32>.stride)
        guard pixels.isEmpty || pixels.count == count else { throw ModularGeometryError.invalidPixels }
        self.width = width; self.height = height
        self.hshift = hshift; self.vshift = vshift
        self.sampleCount = count; self.pixels = pixels
    }

    package func checkPixels() throws {
        guard pixels.count == sampleCount else { throw ModularGeometryError.invalidPixels }
    }

    package mutating func allocatePixels(budget: ScalarOperationBudget) throws {
        guard pixels.isEmpty else { throw ModularGeometryError.populatedGeometry }
        try budget.reserveWorkspace(ScalarOperationBudget.sum(64, ScalarOperationBudget.product(sampleCount, 4)))
        if sampleCount > 0 { ScalarStorageAudit.current?.workingPlane(sampleCount * 4) }
        pixels = [Int32](repeating: 0, count: sampleCount)
    }

    package func sameGeometry(as other: Self) -> Bool {
        width == other.width && height == other.height &&
        hshift == other.hshift && vshift == other.vshift
    }
}

package struct ModularImage: Sendable, Equatable {
    // Implementation admission limits, not JPEG XL format maxima.
    package static let maximumChannels = 4096
    package var channels: [ModularChannel]
    package var nbMetaChannels: Int

    /// The caller admits the initial descriptor array before constructing it.
    package init(channels: [ModularChannel], nbMetaChannels: Int = 0) throws {
        guard channels.count <= Self.maximumChannels else { throw ModularGeometryError.channelLimit }
        guard nbMetaChannels >= 0, nbMetaChannels <= channels.count else {
            throw ModularGeometryError.invalidMetaChannels
        }
        self.channels = channels; self.nbMetaChannels = nbMetaChannels
    }

    package static func admitDescriptors(_ count: Int, budget: ScalarOperationBudget) throws {
        guard count >= 0, count <= maximumChannels else { throw ModularGeometryError.channelLimit }
        // Capacity growth/COW overlap and small array allocation allowance.
        try budget.reserveWorkspace(ScalarOperationBudget.sum(128,
            ScalarOperationBudget.product(count, 2 * MemoryLayout<ModularChannel>.stride)))
    }

    package func checkedRange(begin: UInt32, count: UInt32) throws -> Range<Int> {
        let start = Int(begin), length = Int(count)
        guard length > 0, start <= channels.count, length <= channels.count - start else {
            throw ModularGeometryError.invalidRange
        }
        return start..<(start + length)
    }

    package func checkEqual(_ range: Range<Int>) throws {
        guard range.lowerBound >= nbMetaChannels || range.upperBound <= nbMetaChannels else {
            throw ModularGeometryError.invalidMetaChannels
        }
        let first = channels[range.lowerBound]
        for c in range where !first.sameGeometry(as: channels[c]) {
            throw ModularGeometryError.unequalChannels
        }
    }
}

/// Plan on geometry only. Returns the expanded transform chain that MUST be
/// retained for inversion: defaults depend on the original, unsqueezed shape.
/// Failure invalidates this operation's partially modified working image.
package func metaApplyTransforms(image: inout ModularImage, transforms: [ModularTransform],
                                 budget: ScalarOperationBudget) throws -> [ModularTransform] {
    guard transforms.count <= 256 else { throw ModularGeometryError.invalidTransform }
    guard image.channels.count <= ModularImage.maximumChannels,
          image.nbMetaChannels >= 0, image.nbMetaChannels <= image.channels.count else {
        throw ModularGeometryError.invalidMetaChannels
    }
    guard image.channels.allSatisfy({ $0.pixels.isEmpty }) else {
        throw ModularGeometryError.populatedGeometry
    }
    try budget.reserveWorkspace(ScalarOperationBudget.sum(128,
        ScalarOperationBudget.product(transforms.count, MemoryLayout<ModularTransform>.stride)))
    var expanded: [ModularTransform] = []
    expanded.reserveCapacity(transforms.count)
    for t in transforms {
        try budget.checkpoint()
        switch t.id {
        case .rct:
            guard t.rctType < 42 else { throw ModularGeometryError.invalidTransform }
            try image.checkEqual(image.checkedRange(begin: t.beginC, count: 3))
            expanded.append(t)
        case .palette:
            guard t.nbDeltas == 0, t.palettePredictor == 0 else {
                throw ModularGeometryError.invalidTransform
            }
            let range = try image.checkedRange(begin: t.beginC, count: t.numC)
            try image.checkEqual(range)
            let isMeta = range.lowerBound < image.nbMetaChannels
            guard !isMeta || range.upperBound <= image.nbMetaChannels else {
                throw ModularGeometryError.invalidMetaChannels
            }
            let table = try ModularChannel(width: ScalarOperationBudget.sum(Int(t.nbColors), Int(t.nbDeltas)),
                                           height: range.count, hshift: -1, vshift: -1)
            try ModularImage.admitDescriptors(image.channels.count - range.count + 2, budget: budget)
            image.channels.removeSubrange((range.lowerBound + 1)..<range.upperBound)
            image.channels.insert(table, at: 0)
            image.nbMetaChannels += isMeta ? 2 - range.count : 1
            expanded.append(t)
        case .squeeze:
            guard t.squeezes.count <= 256 else { throw ModularGeometryError.invalidTransform }
            // A default chain has at most two steps per dimension bit plus
            // chroma steps; reserve its bounded descriptor storage up front.
            try budget.reserveWorkspace(256 * MemoryLayout<ModularTransform.SqueezeParams>.stride * 2 + 128)
            let params = t.squeezes.isEmpty ? defaultSqueezeParameters(image: image) : t.squeezes
            for param in params { try metaApplySqueeze(image: &image, param: param, budget: budget) }
            expanded.append(ModularTransform(id: .squeeze, squeezes: params))
        }
    }
    return expanded
}

private func defaultSqueezeParameters(image: ModularImage) -> [ModularTransform.SqueezeParams] {
    let normalCount = image.channels.count - image.nbMetaChannels
    guard normalCount > 0 else { return [] }
    let first = image.nbMetaChannels
    var w = image.channels[first].width, h = image.channels[first].height
    var params: [ModularTransform.SqueezeParams] = []
    if normalCount > 2, image.channels[first + 1].width == w, image.channels[first + 1].height == h {
        params.append(.init(horizontal: true, inPlace: false, beginC: UInt32(first + 1), numC: 2))
        params.append(.init(horizontal: false, inPlace: false, beginC: UInt32(first + 1), numC: 2))
    }
    func add(_ horizontal: Bool) {
        params.append(.init(horizontal: horizontal, inPlace: true, beginC: UInt32(first), numC: UInt32(normalCount)))
    }
    if w <= h, h > 8 { add(false); h = h / 2 + h % 2 }
    while w > 8 || h > 8 {
        if w > 8 { add(true); w = w / 2 + w % 2 }
        if h > 8 { add(false); h = h / 2 + h % 2 }
    }
    return params
}

private func metaApplySqueeze(image: inout ModularImage, param: ModularTransform.SqueezeParams,
                              budget: ScalarOperationBudget) throws {
    try budget.checkpoint()
    let range = try image.checkedRange(begin: param.beginC, count: param.numC)
    let isMeta = range.lowerBound < image.nbMetaChannels
    guard !isMeta || (range.upperBound <= image.nbMetaChannels && param.inPlace) else {
        throw ModularGeometryError.invalidMetaChannels
    }
    try ModularImage.admitDescriptors(image.channels.count + range.count, budget: budget)
    try ModularImage.admitDescriptors(range.count, budget: budget)
    var residuals: [ModularChannel] = []
    residuals.reserveCapacity(range.count)
    for c in range {
        let source = image.channels[c]
        guard source.width > 0, source.height > 0, source.hshift <= 30, source.vshift <= 30 else {
            throw ModularGeometryError.invalidGeometry
        }
        let w = param.horizontal ? source.width / 2 + source.width % 2 : source.width
        let h = param.horizontal ? source.height : source.height / 2 + source.height % 2
        let hs = source.hshift + (param.horizontal && source.hshift >= 0 ? 1 : 0)
        let vs = source.vshift + (!param.horizontal && source.vshift >= 0 ? 1 : 0)
        image.channels[c] = try ModularChannel(width: w, height: h, hshift: hs, vshift: vs)
        residuals.append(try ModularChannel(width: param.horizontal ? source.width - w : w,
            height: param.horizontal ? h : source.height - h, hshift: hs, vshift: vs))
    }
    image.channels.insert(contentsOf: residuals, at: param.inPlace ? range.upperBound : image.channels.count)
    if isMeta { image.nbMetaChannels += range.count }
}
