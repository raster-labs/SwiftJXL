// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

package enum ModularGeometryError: Error, Sendable, Equatable {
    case invalidDimensions
    case invalidPixelCount
    case invalidChannelRange
    case channelMismatch
    case channelLimitExceeded
    case invalidPalette
    case invalidSqueeze
}

/// A single channel in a Modular image or sub-stream (ISO/IEC 18181-1 §8.2).
package struct ModularChannel: Sendable, Equatable {
    package var width: Int
    package var height: Int
    package var hshift: Int
    package var vshift: Int
    package var pixels: [Int32]

    package var sampleCount: Int { width * height }

    package init(
        width: Int,
        height: Int,
        hshift: Int = 0,
        vshift: Int = 0,
        pixels: [Int32] = []
    ) throws {
        guard width >= 0,
              height >= 0,
              Int32(exactly: width) != nil,
              Int32(exactly: height) != nil else {
            throw ModularGeometryError.invalidDimensions
        }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, Int32(exactly: count) != nil else {
            throw ModularGeometryError.invalidDimensions
        }
        guard pixels.isEmpty || pixels.count == count else {
            throw ModularGeometryError.invalidPixelCount
        }
        self.width = width
        self.height = height
        self.hshift = hshift
        self.vshift = vshift
        self.pixels = pixels
    }

    package mutating func resize(
        width: Int,
        height: Int,
        hshift: Int? = nil,
        vshift: Int? = nil
    ) throws {
        guard width >= 0,
              height >= 0,
              Int32(exactly: width) != nil,
              Int32(exactly: height) != nil else {
            throw ModularGeometryError.invalidDimensions
        }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, Int32(exactly: count) != nil else {
            throw ModularGeometryError.invalidDimensions
        }
        self.width = width
        self.height = height
        if let hshift { self.hshift = hshift }
        if let vshift { self.vshift = vshift }
        self.pixels = []
    }

    package mutating func allocatePixels(budget: ScalarOperationBudget) throws {
        let byteCount = try ScalarOperationBudget.product(sampleCount, MemoryLayout<Int32>.stride)
        try budget.reserveWorkspace(ScalarOperationBudget.product(byteCount, 2))
        ScalarStorageAudit.current?.workingPlane(byteCount)
        self.pixels = [Int32](repeating: 0, count: sampleCount)
    }
}

/// Ordered collection of meta-channels and normal channels for a Modular stream (ISO/IEC 18181-1 §8.2).
package struct ModularImage: Sendable, Equatable {
    package static let maximumChannels = 256

    package var channels: [ModularChannel]
    package var nbMetaChannels: Int

    package init(channels: [ModularChannel], nbMetaChannels: Int = 0) throws {
        guard nbMetaChannels >= 0, nbMetaChannels <= channels.count else {
            throw ModularGeometryError.invalidChannelRange
        }
        guard channels.count <= Self.maximumChannels else {
            throw ModularGeometryError.channelLimitExceeded
        }
        self.channels = channels
        self.nbMetaChannels = nbMetaChannels
    }

    package static func admitDescriptors(_ count: Int, budget: ScalarOperationBudget) throws {
        guard count >= 0, count <= Self.maximumChannels else {
            throw ModularGeometryError.channelLimitExceeded
        }
        try budget.reserveWorkspace(
            ScalarOperationBudget.sum(
                128,
                ScalarOperationBudget.product(count, MemoryLayout<ModularChannel>.stride * 2)
            )
        )
    }

    package func checkedRange(begin: Int, count: Int) throws -> Range<Int> {
        guard begin >= 0, count > 0 else {
            throw ModularGeometryError.invalidChannelRange
        }
        let (end, overflow) = begin.addingReportingOverflow(count)
        guard !overflow, end <= channels.count else {
            throw ModularGeometryError.invalidChannelRange
        }
        return begin..<end
    }

    package func checkEqual(_ range: Range<Int>) throws {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= channels.count else {
            throw ModularGeometryError.invalidChannelRange
        }
        let inMeta = range.upperBound <= nbMetaChannels
        let inNormal = range.lowerBound >= nbMetaChannels
        guard inMeta || inNormal else {
            throw ModularGeometryError.channelMismatch
        }
        let first = channels[range.lowerBound]
        for idx in range.dropFirst() {
            let ch = channels[idx]
            guard ch.width == first.width,
                  ch.height == first.height,
                  ch.hshift == first.hshift,
                  ch.vshift == first.vshift else {
                throw ModularGeometryError.channelMismatch
            }
        }
    }
}
