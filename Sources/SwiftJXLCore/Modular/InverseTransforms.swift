// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// ISO/IEC 18181-1 §8.3.2 Table 35 delta palette entries.
private let kDeltaPalette: [(Int32, Int32, Int32)] = [
    (0, 0, 0), (4, 4, 4), (-4, -4, -4), (0, 0, 0),
    (-2, -2, -2), (-2, -2, -1), (-2, -1, -2), (-1, -2, -2),
    (-2, -1, -1), (-1, -2, -1), (-1, -1, -2), (-1, -1, -1),
    (1, 1, 1), (1, 1, 2), (1, 2, 1), (2, 1, 1),
    (1, 2, 2), (2, 1, 2), (2, 2, 1), (2, 2, 2),
    (-4, 0, 0), (0, -4, 0), (0, 0, -4), (-4, -4, 0),
    (0, -4, -4), (-4, 0, -4), (4, 0, 0), (0, 4, 0),
    (0, 0, 4), (4, 4, 0), (0, 4, 4), (4, 0, 4),
    (-8, -8, -8), (8, 8, 8), (-8, 0, 0), (0, -8, 0),
    (0, 0, -8), (-8, -8, 0), (0, -8, -8), (-8, 0, -8),
    (8, 0, 0), (0, 8, 0), (0, 0, 8), (8, 8, 0),
    (0, 8, 8), (8, 0, 8), (-16, -16, -16), (16, 16, 16),
    (-16, 0, 0), (0, -16, 0), (0, 0, -16), (-16, -16, 0),
    (0, -16, -16), (-16, 0, -16), (16, 0, 0), (0, 16, 0),
    (0, 0, 16), (16, 16, 0), (0, 16, 16), (16, 0, 16),
    (-32, -32, -32), (32, 32, 32), (-32, 0, 0), (0, -32, 0),
    (0, 0, -32), (-32, -32, 0), (0, -32, -32), (-32, 0, -32),
    (32, 0, 0), (0, 32, 0), (0, 0, 32), (32, 32, 0),
]

/// Computes the default squeeze parameter list per ISO/IEC 18181-1 §8.5.1.
private func defaultSqueezeParams(for image: ModularImage) -> [ModularTransform.SqueezeParams] {
    let firstNormal = image.nbMetaChannels
    let numNormal = image.channels.count - firstNormal
    guard numNormal > 0 else { return [] }

    var w = image.channels[firstNormal].width
    var h = image.channels[firstNormal].height
    var params: [ModularTransform.SqueezeParams] = []

    if numNormal > 2,
       image.channels[firstNormal + 1].width == w,
       image.channels[firstNormal + 1].height == h,
       image.channels[firstNormal + 2].width == w,
       image.channels[firstNormal + 2].height == h {
        let beginChroma = UInt32(firstNormal + 1)
        if w > 8 {
            params.append(.init(horizontal: true, inPlace: false, beginC: beginChroma, numC: 2))
        }
        if h > 8 {
            params.append(.init(horizontal: false, inPlace: false, beginC: beginChroma, numC: 2))
        }
    }

    let beginAll = UInt32(firstNormal)
    let countAll = UInt32(numNormal)

    if h >= w && h > 8 {
        params.append(.init(horizontal: false, inPlace: true, beginC: beginAll, numC: countAll))
        h = (h + 1) / 2
    }
    while w > 8 || h > 8 {
        if w > 8 {
            params.append(.init(horizontal: true, inPlace: true, beginC: beginAll, numC: countAll))
            w = (w + 1) / 2
        }
        if h > 8 {
            params.append(.init(horizontal: false, inPlace: true, beginC: beginAll, numC: countAll))
            h = (h + 1) / 2
        }
    }
    return params
}

/// Applies forward meta-transforms to channel geometry before entropy decoding (ISO/IEC 18181-1 §§8.2–8.5).
package func metaApplyTransforms(
    image: inout ModularImage,
    transforms: [ModularTransform],
    budget: ScalarOperationBudget
) throws -> [ModularTransform] {
    try budget.checkpoint()
    var working = image
    var resolved: [ModularTransform] = []
    resolved.reserveCapacity(transforms.count)

    for transform in transforms {
        try budget.checkpoint()
        switch transform.id {
        case .rct:
            guard transform.rctType < 42,
                  let begin = Int(exactly: transform.beginC),
                  begin >= 0 else {
                throw ModularGeometryError.invalidChannelRange
            }
            let (end, over) = begin.addingReportingOverflow(3)
            guard !over, end <= working.channels.count else {
                throw ModularGeometryError.invalidChannelRange
            }
            guard end <= working.nbMetaChannels || begin >= working.nbMetaChannels else {
                throw ModularGeometryError.invalidChannelRange
            }
            let c0 = working.channels[begin]
            let c1 = working.channels[begin + 1]
            let c2 = working.channels[begin + 2]
            guard c0.width == c1.width, c0.width == c2.width,
                  c0.height == c1.height, c0.height == c2.height,
                  c0.hshift == c1.hshift, c0.hshift == c2.hshift,
                  c0.vshift == c1.vshift, c0.vshift == c2.vshift else {
                throw ModularGeometryError.channelMismatch
            }
            resolved.append(transform)

        case .palette:
            guard let begin = Int(exactly: transform.beginC),
                  let numC = Int(exactly: transform.numC),
                  let nbColors = Int(exactly: transform.nbColors),
                  begin >= 0, numC > 0, nbColors >= 0, nbColors <= 65536 else {
                throw ModularGeometryError.invalidPalette
            }
            let (end, over) = begin.addingReportingOverflow(numC)
            guard !over, end <= working.channels.count else {
                throw ModularGeometryError.invalidChannelRange
            }
            guard end <= working.nbMetaChannels || begin >= working.nbMetaChannels else {
                throw ModularGeometryError.invalidChannelRange
            }
            let first = working.channels[begin]
            for i in (begin + 1)..<end {
                let ch = working.channels[i]
                guard ch.width == first.width,
                      ch.height == first.height,
                      ch.hshift == first.hshift,
                      ch.vshift == first.vshift else {
                    throw ModularGeometryError.channelMismatch
                }
            }
            guard transform.nbDeltas == 0, transform.palettePredictor == 0 else {
                throw ScalarModularError.unsupportedProfile
            }
            let newTotalChannels = working.channels.count + 2 - numC
            try ModularImage.admitDescriptors(newTotalChannels, budget: budget)

            let paletteChannel = try ModularChannel(
                width: nbColors,
                height: numC,
                hshift: -1,
                vshift: -1
            )
            if begin < working.nbMetaChannels {
                working.nbMetaChannels = working.nbMetaChannels + 2 - numC
            } else {
                working.nbMetaChannels += 1
            }
            if numC > 1 {
                working.channels.removeSubrange((begin + 1)..<end)
            }
            working.channels.insert(paletteChannel, at: 0)
            resolved.append(transform)

        case .squeeze:
            let squeezes = transform.squeezes.isEmpty
                ? defaultSqueezeParams(for: working)
                : transform.squeezes
            guard !squeezes.isEmpty else {
                throw ModularGeometryError.invalidSqueeze
            }
            for sp in squeezes {
                try budget.checkpoint()
                guard let begin = Int(exactly: sp.beginC),
                      let count = Int(exactly: sp.numC),
                      begin >= 0, count > 0 else {
                    throw ModularGeometryError.invalidSqueeze
                }
                let (end, over) = begin.addingReportingOverflow(count)
                guard !over, end <= working.channels.count else {
                    throw ModularGeometryError.invalidSqueeze
                }
                if begin < working.nbMetaChannels {
                    guard end <= working.nbMetaChannels, sp.inPlace else {
                        throw ModularGeometryError.invalidSqueeze
                    }
                }
                let (nextTotal, totalOver) = working.channels.count.addingReportingOverflow(count)
                guard !totalOver else {
                    throw ModularGeometryError.channelLimitExceeded
                }
                try ModularImage.admitDescriptors(nextTotal, budget: budget)

                var residuals: [ModularChannel] = []
                residuals.reserveCapacity(count)
                for i in begin..<end {
                    let ch = working.channels[i]
                    guard ch.hshift < 30, ch.vshift < 30 else {
                        throw ModularGeometryError.invalidSqueeze
                    }
                    if sp.horizontal {
                        let lowW = (ch.width + 1) / 2
                        let highW = ch.width / 2
                        let nextHShift = ch.hshift >= 0 ? ch.hshift + 1 : ch.hshift
                        working.channels[i] = try ModularChannel(
                            width: lowW,
                            height: ch.height,
                            hshift: nextHShift,
                            vshift: ch.vshift
                        )
                        residuals.append(try ModularChannel(
                            width: highW,
                            height: ch.height,
                            hshift: nextHShift,
                            vshift: ch.vshift
                        ))
                    } else {
                        let lowH = (ch.height + 1) / 2
                        let highH = ch.height / 2
                        let nextVShift = ch.vshift >= 0 ? ch.vshift + 1 : ch.vshift
                        working.channels[i] = try ModularChannel(
                            width: ch.width,
                            height: lowH,
                            hshift: ch.hshift,
                            vshift: nextVShift
                        )
                        residuals.append(try ModularChannel(
                            width: ch.width,
                            height: highH,
                            hshift: ch.hshift,
                            vshift: nextVShift
                        ))
                    }
                }
                let insertAt = sp.inPlace ? end : working.channels.count
                working.channels.insert(contentsOf: residuals, at: insertAt)
                if begin < working.nbMetaChannels {
                    working.nbMetaChannels += count
                }
            }
            resolved.append(ModularTransform(id: .squeeze, squeezes: squeezes))
        }
    }

    image = working
    return resolved
}

/// Applies inverse Modular transforms in reverse order to reconstruct sample planes (ISO/IEC 18181-1 §§8.2–8.5).
package func applyInverseTransforms(
    image: inout ModularImage,
    transforms: [ModularTransform],
    bitDepth: Int,
    budget: ScalarOperationBudget
) throws {
    try budget.checkpoint()
    guard (1...31).contains(bitDepth) else {
        throw ModularGeometryError.invalidDimensions
    }
    var working = image

    for transform in transforms.reversed() {
        try budget.checkpoint()
        switch transform.id {
        case .rct:
            guard let begin = Int(exactly: transform.beginC),
                  begin >= 0 else {
                throw ModularGeometryError.invalidChannelRange
            }
            let (end, over) = begin.addingReportingOverflow(3)
            guard !over, end <= working.channels.count else {
                throw ModularGeometryError.invalidChannelRange
            }
            guard end <= working.nbMetaChannels || begin >= working.nbMetaChannels else {
                throw ModularGeometryError.invalidChannelRange
            }
            let c0 = working.channels[begin]
            let c1 = working.channels[begin + 1]
            let c2 = working.channels[begin + 2]
            guard c0.width == c1.width, c0.width == c2.width,
                  c0.height == c1.height, c0.height == c2.height,
                  c0.hshift == c1.hshift, c0.hshift == c2.hshift,
                  c0.vshift == c1.vshift, c0.vshift == c2.vshift,
                  c0.pixels.count == c0.sampleCount,
                  c1.pixels.count == c1.sampleCount,
                  c2.pixels.count == c2.sampleCount else {
                throw ModularGeometryError.channelMismatch
            }
            var p0 = working.channels[begin].pixels
            var p1 = working.channels[begin + 1].pixels
            var p2 = working.channels[begin + 2].pixels
            working.channels[begin].pixels = []
            working.channels[begin + 1].pixels = []
            working.channels[begin + 2].pixels = []
            try SpecRCT.inverse(
                rctType: transform.rctType,
                channel0: &p0,
                channel1: &p1,
                channel2: &p2,
                checkpoint: budget.checkpoint
            )
            working.channels[begin].pixels = p0
            working.channels[begin + 1].pixels = p1
            working.channels[begin + 2].pixels = p2

        case .palette:
            guard transform.nbDeltas == 0, transform.palettePredictor == 0 else {
                throw ScalarModularError.unsupportedProfile
            }
            guard let begin = Int(exactly: transform.beginC),
                  let numC = Int(exactly: transform.numC),
                  let nbColors = Int(exactly: transform.nbColors),
                  begin >= 0, numC > 0, nbColors >= 0,
                  working.nbMetaChannels >= 1,
                  begin + 1 < working.channels.count else {
                throw ModularGeometryError.invalidPalette
            }
            let paletteChannel = working.channels[0]
            let indexChannel = working.channels[begin + 1]
            guard paletteChannel.width == nbColors,
                  paletteChannel.height == numC,
                  paletteChannel.pixels.count == paletteChannel.sampleCount,
                  indexChannel.pixels.count == indexChannel.sampleCount else {
                throw ModularGeometryError.invalidPalette
            }
            let newTotal = working.channels.count - 2 + numC
            try ModularImage.admitDescriptors(newTotal, budget: budget)

            let sampleCount = indexChannel.sampleCount
            let palettePixels = paletteChannel.pixels
            let indices = indexChannel.pixels
            let maxVal = (Int64(1) << bitDepth) - 1
            let cubeOffset = Int32(1 << max(0, bitDepth - 3))

            var restored: [ModularChannel] = []
            restored.reserveCapacity(numC)
            for c in 0..<numC {
                var outCh = try ModularChannel(
                    width: indexChannel.width,
                    height: indexChannel.height,
                    hshift: indexChannel.hshift,
                    vshift: indexChannel.vshift
                )
                try outCh.allocatePixels(budget: budget)
                let palRowOffset = c * nbColors
                outCh.pixels.withUnsafeMutableBufferPointer { dstBuf in
                    guard let dst = dstBuf.baseAddress else { return }
                    for i in 0..<sampleCount {
                        let idx = Int(indices[i])
                        let val: Int32
                        if idx < 0 {
                            let dIdx = -1 - idx
                            if c < 3 && dIdx < kDeltaPalette.count {
                                let entry = kDeltaPalette[dIdx]
                                let rawDelta: Int32 = (c == 0) ? entry.0 : ((c == 1) ? entry.1 : entry.2)
                                if bitDepth > 8 {
                                    val = rawDelta << min(23, bitDepth - 8)
                                } else if bitDepth < 8 {
                                    val = rawDelta >> (8 - bitDepth)
                                } else {
                                    val = rawDelta
                                }
                            } else {
                                val = 0
                            }
                        } else if idx < nbColors {
                            val = palettePixels[palRowOffset + idx]
                        } else if idx < nbColors + 64 {
                            let k = idx - nbColors
                            let shift = 2 * c
                            let v = shift < 30 ? ((k >> shift) & 3) : 0
                            let scaled = Int32(truncatingIfNeeded: (Int64(v) * maxVal) >> 2)
                            val = scaled &+ cubeOffset
                        } else {
                            val = 0
                        }
                        dst[i] = val
                    }
                }
                restored.append(outCh)
            }

            let wasMeta = (begin + 1) < working.nbMetaChannels
            working.channels.removeFirst()
            working.channels.replaceSubrange(begin..<(begin + 1), with: restored)
            if wasMeta {
                working.nbMetaChannels = working.nbMetaChannels - 2 + numC
            } else {
                working.nbMetaChannels -= 1
            }

        case .squeeze:
            guard !transform.squeezes.isEmpty else {
                throw ModularGeometryError.invalidSqueeze
            }
            for sp in transform.squeezes.reversed() {
                try budget.checkpoint()
                guard let begin = Int(exactly: sp.beginC),
                      let count = Int(exactly: sp.numC),
                      begin >= 0, count > 0 else {
                    throw ModularGeometryError.invalidSqueeze
                }
                let (end, over) = begin.addingReportingOverflow(count)
                guard !over, end <= working.channels.count else {
                    throw ModularGeometryError.invalidSqueeze
                }
                let residualBegin = sp.inPlace ? end : (working.channels.count - count)
                let (residualEnd, resOver) = residualBegin.addingReportingOverflow(count)
                guard !resOver,
                      end <= residualBegin,
                      residualEnd <= working.channels.count else {
                    throw ModularGeometryError.invalidSqueeze
                }
                if begin < working.nbMetaChannels {
                    guard sp.inPlace, residualEnd <= working.nbMetaChannels else {
                        throw ModularGeometryError.invalidSqueeze
                    }
                } else {
                    guard residualBegin >= working.nbMetaChannels else {
                        throw ModularGeometryError.invalidSqueeze
                    }
                }

                for offset in 0..<count {
                    let ll = working.channels[begin + offset]
                    let res = working.channels[residualBegin + offset]
                    working.channels[begin + offset] = try SpecSqueeze.inverse(
                        ll: ll,
                        residual: res,
                        horizontal: sp.horizontal,
                        budget: budget
                    )
                }
                working.channels.removeSubrange(residualBegin..<residualEnd)
                if begin < working.nbMetaChannels {
                    working.nbMetaChannels -= count
                }
            }
        }
    }

    image = working
}
