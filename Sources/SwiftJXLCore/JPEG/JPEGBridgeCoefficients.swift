// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Resource, geometry, and cancellation policy for the ISO/IEC 18181-1 VarDCT JPEG coefficient bridge.
package struct JPEGBridgePolicy: Sendable {
    package let maximumCoefficientBytes: Int
    package let maximumMemoryBytes: Int
    package let maximumDimension: Int
    package let maximumPixels: Int
    package let maximumNestingDepth: Int
    package let maximumICCBytes: Int
    package let deadline: ContinuousClock.Instant
    package let checkpointClosure: @Sendable () throws -> Void

    package init(
        maximumCoefficientBytes: Int = 64 * 1024 * 1024,
        maximumMemoryBytes: Int = 256 * 1024 * 1024,
        maximumDimension: Int = 2048,
        maximumPixels: Int = 2048 * 2048,
        maximumNestingDepth: Int = 32,
        maximumICCBytes: Int = 4 * 1024 * 1024,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(10)),
        checkpoint: @escaping @Sendable () throws -> Void = {}
    ) throws {
        guard maximumCoefficientBytes > 0,
              maximumMemoryBytes > 0,
              maximumDimension > 0,
              maximumPixels > 0,
              maximumNestingDepth > 0,
              maximumICCBytes > 0 else {
            throw JPEGEntropyError.resourceLimit
        }
        self.maximumCoefficientBytes = maximumCoefficientBytes
        self.maximumMemoryBytes = maximumMemoryBytes
        self.maximumDimension = maximumDimension
        self.maximumPixels = maximumPixels
        self.maximumNestingDepth = maximumNestingDepth
        self.maximumICCBytes = maximumICCBytes
        self.deadline = deadline
        self.checkpointClosure = checkpoint
    }

    package func checkpoint() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw JPEGEntropyError.resourceLimit
        }
        try checkpointClosure()
    }
}

/// Zero-copy transposed view over decoded JPEG 8x8 DCT coefficient planes in JXL `[c = 0(Cb/G), 1(Y/R), 2(Cr/B)]` order.
package struct JPEGBridgeCoefficients: Sendable {
    package struct ChannelLayout: Sendable, Equatable {
        package let jpegComponent: Int?
        package let visibleBlocksWide: Int
        package let visibleBlocksHigh: Int
        package let blocksWide: Int
        package let blocksHigh: Int
        package let horizontalShift: Int
        package let verticalShift: Int
    }

    package let frame: JPEGFrameLayout
    package let channels: [ChannelLayout]
    package let sourceCoefficients: [[Int32]]
    package let quantisation: [Int32]
    package let dcQuantisation: [Float]
    package let quantisationDenominator: Float
    package let chromaSubsampling: YCbCrChromaSubsampling
    package let colourTransform: ColorTransform
    package let admittedBytes: Int
    package let policy: JPEGBridgePolicy

    package init(
        frame: JPEGFrameLayout,
        coefficients: [[Int32]],
        quantisation: [[UInt16]],
        colourTransform: ColorTransform = .yCbCr,
        policy: JPEGBridgePolicy
    ) throws {
        try policy.checkpoint()
        guard frame.precision == 8,
              [UInt8(0xC0), 0xC1, 0xC2].contains(frame.marker) else {
            throw JPEGEntropyError.unsupported
        }
        guard coefficients.count == frame.components.count,
              quantisation.count == frame.components.count else {
            throw JPEGEntropyError.malformed
        }

        for i in 0..<frame.components.count {
            let comp = frame.components[i]
            let expectedCount = comp.paddedBlocksWide * comp.paddedBlocksHigh * 64
            guard coefficients[i].count == expectedCount,
                  quantisation[i].count == 64,
                  quantisation[i].allSatisfy({ $0 > 0 }) else {
                throw JPEGEntropyError.malformed
            }
        }

        let (coeffBytes, coeffOverflow) = frame.coefficientCount.multipliedReportingOverflow(
            by: MemoryLayout<Int32>.stride
        )
        let (doubleBytes, dblOverflow) = coeffBytes.multipliedReportingOverflow(by: 2)
        let (admitted, admOverflow) = doubleBytes.addingReportingOverflow(16384)
        guard !coeffOverflow, !dblOverflow, !admOverflow,
              coeffBytes <= policy.maximumCoefficientBytes,
              admitted <= policy.maximumMemoryBytes else {
            throw JPEGEntropyError.resourceLimit
        }

        guard colourTransform == .yCbCr || colourTransform == .none else {
            throw JPEGEntropyError.unsupported
        }

        let maxH = frame.components.map(\.horizontalSampling).max() ?? 1
        let maxV = frame.components.map(\.verticalSampling).max() ?? 1

        func samplingMode(h: Int, v: Int) throws -> UInt32 {
            switch (h, v) {
            case (1, 1): return 0
            case (2, 2): return 1
            case (2, 1): return 2
            case (1, 2): return 3
            default: throw JPEGEntropyError.unsupported
            }
        }

        let componentOrder: [Int]
        let subsampling: YCbCrChromaSubsampling
        if frame.components.count == 1 {
            guard frame.components[0].horizontalSampling == 1,
                  frame.components[0].verticalSampling == 1 else {
                throw JPEGEntropyError.unsupported
            }
            componentOrder = [0, 0, 0]
            subsampling = YCbCrChromaSubsampling(y: 0, cb: 0, cr: 0)
        } else if frame.components.count == 3 {
            componentOrder = (colourTransform == .none) ? [0, 1, 2] : [1, 0, 2]
            for comp in frame.components {
                guard maxH % comp.horizontalSampling == 0,
                      maxV % comp.verticalSampling == 0 else {
                    throw JPEGEntropyError.unsupported
                }
            }
            let mode0 = try samplingMode(
                h: frame.components[componentOrder[0]].horizontalSampling,
                v: frame.components[componentOrder[0]].verticalSampling
            )
            let mode1 = try samplingMode(
                h: frame.components[componentOrder[1]].horizontalSampling,
                v: frame.components[componentOrder[1]].verticalSampling
            )
            let mode2 = try samplingMode(
                h: frame.components[componentOrder[2]].horizontalSampling,
                v: frame.components[componentOrder[2]].verticalSampling
            )
            let sub = YCbCrChromaSubsampling(y: mode0, cb: mode1, cr: mode2)
            if colourTransform == .none && !sub.is444 {
                throw JPEGEntropyError.unsupported
            }
            subsampling = sub
        } else {
            throw JPEGEntropyError.unsupported
        }

        var channelLayouts: [ChannelLayout] = []
        channelLayouts.reserveCapacity(3)
        var flatQuant = [Int32](repeating: 0, count: 192)
        var dcQuant = [Float](repeating: 0, count: 3)

        for c in 0..<3 {
            let srcIdx = componentOrder[c]
            let comp = frame.components[srcIdx]
            let hShift = subsampling.hShift(c)
            let vShift = subsampling.vShift(c)
            guard (maxH >> hShift) == comp.horizontalSampling,
                  (maxV >> vShift) == comp.verticalSampling else {
                throw JPEGEntropyError.unsupported
            }
            let jpegComp: Int? = (frame.components.count == 1 && c != 1) ? nil : srcIdx
            channelLayouts.append(
                ChannelLayout(
                    jpegComponent: jpegComp,
                    visibleBlocksWide: comp.visibleBlocksWide,
                    visibleBlocksHigh: comp.visibleBlocksHigh,
                    blocksWide: comp.paddedBlocksWide,
                    blocksHigh: comp.paddedBlocksHigh,
                    horizontalShift: hShift,
                    verticalShift: vShift
                )
            )
            let qSrc = quantisation[srcIdx]
            for y in 0..<8 {
                for x in 0..<8 {
                    flatQuant[c * 64 + y * 8 + x] = Int32(qSrc[x * 8 + y])
                }
            }
            dcQuant[c] = 2040.0 / Float(qSrc[0])
        }

        self.frame = frame
        self.channels = channelLayouts
        self.sourceCoefficients = coefficients
        self.quantisation = flatQuant
        self.dcQuantisation = dcQuant
        self.quantisationDenominator = Float(1.0 / 2040.0)
        self.chromaSubsampling = subsampling
        self.colourTransform = colourTransform
        self.admittedBytes = admitted
        self.policy = policy
    }

    package func readBlock(
        channel: Int,
        block: Int,
        into scratch: inout [Int32]
    ) throws {
        try policy.checkpoint()
        guard (0..<3).contains(channel), scratch.count == 64 else {
            throw JPEGEntropyError.malformed
        }
        let layout = channels[channel]
        let totalBlocks = layout.blocksWide * layout.blocksHigh
        guard block >= 0, block < totalBlocks else {
            throw JPEGEntropyError.malformed
        }
        guard let ci = layout.jpegComponent else {
            for k in 0..<64 {
                scratch[k] = 0
            }
            return
        }
        let base = block * 64
        let plane = sourceCoefficients[ci]
        guard base >= 0, base + 64 <= plane.count else {
            throw JPEGEntropyError.malformed
        }

        var dcValue = plane[base]
        if colourTransform == .none {
            let qDC = quantisation[channel * 64]
            guard qDC > 0 else { throw JPEGEntropyError.malformed }
            let dcOffset = Int32(1024) / qDC
            let (shifted, overflow) = dcValue.addingReportingOverflow(dcOffset)
            guard !overflow else {
                throw JPEGEntropyError.malformed
            }
            dcValue = shifted
        }

        for j in 0..<8 {
            for i in 0..<8 {
                scratch[j * 8 + i] = plane[base + i * 8 + j]
            }
        }
        scratch[0] = dcValue
    }
}
