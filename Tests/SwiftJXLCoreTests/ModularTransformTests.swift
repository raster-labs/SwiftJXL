// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct ModularTransformTests {
    private func budget(_ workspace: Int = 16 * 1024 * 1024,
                        expired: Bool = false) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: workspace,
            maximumMemoryBytes: 32 * 1024 * 1024, maximumDecodedBytes: 16 * 1024 * 1024,
            maximumCompressedBytes: 1024, deadline: .now.advanced(by: .seconds(expired ? -1 : 60)))
    }

    private struct Vector: Decodable {
        let horizontal: Bool
        let width: Int
        let height: Int
        let low: [Int32]
        let high: [Int32]
        let output: [Int32]
    }

    @Test(arguments: [true, false])
    func squeezeMatchesPinnedPredecessorWithOddTailsAndExtremes(_ horizontal: Bool) throws {
        let url = try #require(Bundle.module.url(forResource: "squeeze-baseline", withExtension: "json", subdirectory: "Modular"))
        let cases = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        for v in cases where v.horizontal == horizontal {
            let low = try ModularChannel(width: horizontal ? (v.width + 1) / 2 : v.width,
                height: horizontal ? v.height : (v.height + 1) / 2,
                hshift: horizontal ? 1 : 0, vshift: horizontal ? 0 : 1, pixels: v.low)
            let high = try ModularChannel(width: horizontal ? v.width / 2 : v.width,
                height: horizontal ? v.height : v.height / 2,
                hshift: low.hshift, vshift: low.vshift, pixels: v.high)
            let output = try SpecSqueeze.inverse(ll: low, residual: high, horizontal: horizontal, budget: budget())
            #expect(output.width == v.width && output.height == v.height)
            #expect(output.hshift == 0 && output.vshift == 0)
            #expect(output.pixels == v.output)
        }
    }

    @Test func implicitSqueezeRetainsOriginalPlanAndRestoresGeometry() throws {
        let b = try budget()
        var image = try ModularImage(channels: (0..<3).map { _ in try ModularChannel(width: 17, height: 9) })
        let plan = try metaApplyTransforms(image: &image, transforms: [.init(id: .squeeze)], budget: b)
        #expect(plan[0].squeezes.count == 5)
        #expect(image.channels.count == 16)
        #expect(image.channels.allSatisfy { $0.pixels.isEmpty })
        for c in image.channels.indices { try image.channels[c].allocatePixels(budget: b) }
        try applyInverseTransforms(image: &image, transforms: plan, bitDepth: 16, budget: b)
        #expect(image.channels.count == 3 && image.nbMetaChannels == 0)
        #expect(image.channels.allSatisfy { $0.width == 17 && $0.height == 9 && $0.hshift == 0 && $0.vshift == 0 })
        #expect(image.channels.allSatisfy { $0.pixels == [Int32](repeating: 0, count: 153) })
    }

    @Test func paletteUsesActualPrecisionAndRestoresFirstNormalChannel() throws {
        let b = try budget()
        var image = try ModularImage(channels: (0..<3).map { _ in try ModularChannel(width: 7, height: 1) })
        let plan = try metaApplyTransforms(image: &image,
            transforms: [.init(id: .palette, numC: 3, nbColors: 2)], budget: b)
        #expect(image.nbMetaChannels == 1 && image.channels.count == 2)
        image.channels[0].pixels = [10, 20, 30, 40, 50, 60]
        image.channels[1].pixels = [0, 1, 2, 65, 66, -2, -3]
        try applyInverseTransforms(image: &image, transforms: plan, bitDepth: 16, budget: b)
        #expect(image.nbMetaChannels == 0 && image.channels.count == 3)
        #expect(image.channels[0].pixels == [10, 20, 8192, 57343, 0, 1024, -1024])
        #expect(image.channels[1].pixels == [30, 40, 8192, 57343, 0, 1024, -1024])
        #expect(image.channels[2].pixels == [50, 60, 8192, 57343, 0, 1024, -1024])
    }

    @Test func metaPaletteAndSqueezeRestoreMetaChannelCountAndShifts() throws {
        let b = try budget()
        var image = try ModularImage(channels: (0..<3).map { _ in
            try ModularChannel(width: 3, height: 1, hshift: -1, vshift: -1)
        }, nbMetaChannels: 3)
        let transforms: [ModularTransform] = [.init(id: .palette, numC: 3, nbColors: 2),
            .init(id: .squeeze, squeezes: [.init(horizontal: true, inPlace: true, beginC: 1, numC: 1)])]
        let plan = try metaApplyTransforms(image: &image, transforms: transforms, budget: b)
        #expect(image.nbMetaChannels == 3 && image.channels.count == 3)
        image.channels[0].pixels = [11, 12, 21, 22, 31, 32]
        image.channels[1].pixels = [0, 1]
        image.channels[2].pixels = [0]
        try applyInverseTransforms(image: &image, transforms: plan, bitDepth: 8, budget: b)
        #expect(image.nbMetaChannels == 3 && image.channels.count == 3)
        #expect(image.channels.allSatisfy { $0.hshift == -1 && $0.vshift == -1 })
        #expect(image.channels[0].pixels == [11, 11, 12])
        #expect(image.channels[1].pixels == [21, 21, 22])
        #expect(image.channels[2].pixels == [31, 31, 32])
    }

    @Test func geometryRejectsOverflowAndMetaMixWithoutPixelAllocation() throws {
        #expect(throws: (any Error).self) { try ModularChannel(width: Int.max, height: 2) }
        #expect(throws: (any Error).self) { try ModularChannel(width: -1, height: 0) }
        #expect(throws: (any Error).self) { try ModularChannel(width: 4, height: 4, pixels: [1]) }
        let channel = try ModularChannel(width: 8, height: 8)
        var image = try ModularImage(channels: [channel, channel], nbMetaChannels: 1)
        #expect(throws: ModularGeometryError.self) {
            try metaApplyTransforms(image: &image, transforms: [.init(id: .palette, numC: 2)], budget: budget())
        }
        #expect(image.channels.allSatisfy { $0.pixels.isEmpty })
        #expect(throws: ModularGeometryError.self) {
            try metaApplyTransforms(image: &image, transforms: [.init(id: .squeeze, squeezes: [
                .init(horizontal: true, inPlace: false, beginC: 0, numC: 1)])], budget: budget())
        }
        #expect(throws: ModularGeometryError.self) {
            try metaApplyTransforms(image: &image, transforms: [.init(id: .rct, beginC: .max)], budget: budget())
        }
    }

    @Test func malformedResidualsAndMissingPlanesRejectBeforeAllocation() throws {
        let b = try budget()
        let ll = try ModularChannel(width: 3, height: 1, hshift: 1, pixels: [1, 2, 3])
        let short = try ModularChannel(width: 1, height: 1, hshift: 1, pixels: [4])
        #expect(throws: ModularGeometryError.self) {
            try SpecSqueeze.inverse(ll: ll, residual: short, horizontal: true, budget: b)
        }
        let absent = try ModularChannel(width: 2, height: 1, hshift: 1)
        #expect(throws: ModularGeometryError.self) {
            try SpecSqueeze.inverse(ll: ll, residual: absent, horizontal: true, budget: b)
        }
        #expect(b.reservedWorkspaceBytes == 0)
        var overlapping = try ModularImage(channels: [ll])
        #expect(throws: ModularGeometryError.self) {
            try applyInverseTransforms(image: &overlapping, transforms: [.init(id: .squeeze, squeezes: [
                .init(horizontal: true, inPlace: false, numC: 1)])], bitDepth: 8, budget: b)
        }
    }

    @Test func resourceAndDeadlineLimitsApplyBeforePlanesAreAllocated() throws {
        var channel = try ModularChannel(width: 100, height: 100)
        #expect(throws: ScalarModularError.self) { try channel.allocatePixels(budget: budget(128)) }
        #expect(channel.pixels.isEmpty)
        #expect(throws: ScalarModularError.self) { try channel.allocatePixels(budget: budget(expired: true)) }
        #expect(channel.pixels.isEmpty)
        var image = try ModularImage(channels: [channel])
        #expect(throws: ScalarModularError.self) {
            try metaApplyTransforms(image: &image, transforms: [.init(id: .squeeze)], budget: budget(128))
        }
        #expect(image.channels.count == 1 && image.channels[0].pixels.isEmpty)
    }

    @Test func channelExpansionAndUnsupportedPalettesAreBounded() throws {
        let channel = try ModularChannel(width: 2, height: 1)
        var full = try ModularImage(channels: Array(repeating: channel, count: ModularImage.maximumChannels))
        #expect(throws: ModularGeometryError.self) {
            try metaApplyTransforms(image: &full, transforms: [.init(id: .squeeze, squeezes: [
                .init(horizontal: true, inPlace: true, numC: 1)])], budget: budget())
        }
        #expect(full.channels.count == ModularImage.maximumChannels)
        for transform in [ModularTransform(id: .palette, numC: 1, nbDeltas: 1),
                          ModularTransform(id: .palette, numC: 1, palettePredictor: 1)] {
            var image = try ModularImage(channels: [channel])
            #expect(throws: ModularGeometryError.self) {
                try metaApplyTransforms(image: &image, transforms: [transform], budget: budget())
            }
            #expect(image.channels.count == 1 && image.channels[0].pixels.isEmpty)
        }
    }

    @Test func rctChainPreservesOtherOwnersAndRejectsCancelledWork() async throws {
        let channels = try [[Int32](repeating: 10, count: 4), [Int32](repeating: 20, count: 4),
                            [Int32](repeating: 30, count: 4)].map {
            try ModularChannel(width: 2, height: 2, pixels: $0)
        }
        var image = try ModularImage(channels: channels)
        try applyInverseTransforms(image: &image, transforms: [.init(id: .rct)], bitDepth: 16, budget: budget())
        #expect(channels[0].pixels == [10, 10, 10, 10])
        #expect(image.channels.map(\.pixels) == [[5, 5, 5, 5], [25, 25, 25, 25], [-15, -15, -15, -15]])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var cancelled = try ModularImage(channels: channels)
            let unchanged = cancelled
            #expect(throws: CancellationError.self) {
                try applyInverseTransforms(image: &cancelled, transforms: [.init(id: .rct)], bitDepth: 8, budget: budget())
            }
            #expect(cancelled == unchanged)
        }
        try await task.value
    }
}
