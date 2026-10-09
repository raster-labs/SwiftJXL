// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift JPEG/JPEGToJXLAdapter.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e and libjxl enc_frame.cc at
// a7a9c787341cf703dede03c2009fa460cae5e5df, Copyright the JPEG XL Project Authors.
// See Documentation/ThirdParty/libjxl-LICENSE.txt.
import Foundation

package struct JPEGBridgePolicy: Sendable {
    package let maximumCoefficientBytes: Int
    package let maximumMemoryBytes: Int
    package let maximumDimension: Int
    package let maximumPixels: Int
    package let maximumICCBytes: Int
    package let maximumNestingDepth: Int
    package let deadline: ContinuousClock.Instant
    private let work: @Sendable () throws -> Void

    package init(maximumCoefficientBytes: Int = 64 * 1024 * 1024,
                 maximumMemoryBytes: Int = 256 * 1024 * 1024,
                 maximumDimension: Int = 2048, maximumPixels: Int = 2048 * 2048,
                 maximumNestingDepth: Int = 32, maximumICCBytes: Int = 4 * 1024 * 1024,
                 deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(10)),
                 checkpoint: @escaping @Sendable () throws -> Void = {}) throws {
        guard maximumCoefficientBytes > 0, maximumMemoryBytes > 0,
              maximumDimension > 0, maximumPixels > 0, maximumNestingDepth > 0, maximumICCBytes > 0 else {
            throw JPEGEntropyError.resourceLimit
        }
        self.maximumCoefficientBytes = maximumCoefficientBytes
        self.maximumMemoryBytes = maximumMemoryBytes
        self.maximumDimension = maximumDimension; self.maximumPixels = maximumPixels
        self.maximumNestingDepth = maximumNestingDepth; self.maximumICCBytes = min(maximumICCBytes, 4 * 1024 * 1024)
        self.deadline = deadline; self.work = checkpoint
    }

    package func checkpoint() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw JPEGEntropyError.resourceLimit }
        try work()
    }
}

/// A bounded view of immutable JPEG coefficient owners in JXL channel order.
/// No source JPEG, pixels, full DC/AC planes or arrays of block arrays are kept.
/// The future frame writer consumes one reusable 64-value scratch block.
/// This is a data adapter, not an encoder or proof of JXL interoperability.
package struct JPEGBridgeCoefficients: Sendable {
    package struct Channel: Sendable {
        /// Nil denotes an implicit zero chroma plane for greyscale.
        package let jpegComponent: Int?
        package let blocksWide: Int
        package let blocksHigh: Int
        package let visibleBlocksWide: Int
        package let visibleBlocksHigh: Int
        package let dcOffset: Int32
    }

    package let frame: JPEGFrameLayout
    package let colourTransform: ColorTransform
    package let chromaSubsampling: YCbCrChromaSubsampling
    package let channels: [Channel]
    /// Retained immutable owners, still in JPEG component/natural coefficient order.
    package let sourceCoefficients: [[Int32]]
    /// Channel-major, transposed natural-order RAW quantisation values (3 × 64).
    package let quantisation: [Int32]
    package let quantisationDenominator: Float = 1 / (8 * 255)
    package let dcQuantisation: [Float]
    /// Conservative bound for this adapter's live owners and one block scratch.
    /// The caller must separately admit input, metadata and frame-writer storage.
    package let admittedBytes: Int
    private let policy: JPEGBridgePolicy

    package init(frame: JPEGFrameLayout, coefficients: [[Int32]], quantisation: [[UInt16]],
                 colourTransform: ColorTransform = .yCbCr, policy: JPEGBridgePolicy) throws {
        try policy.checkpoint()
        let count = frame.components.count
        guard count == 1 || count == 3, coefficients.count == count,
              quantisation.count == count else { throw JPEGEntropyError.malformed }
        guard colourTransform == .yCbCr || colourTransform == .none else {
            throw JPEGEntropyError.unsupported
        }
        // Two retained coefficient bounds cover input array capacity; 16 KiB
        // covers outer arrays, channel/quantisation records and block scratch.
        // No image-sized coefficient copy or implicit zero plane is allocated.
        let fixed = 16 * 1024
        guard frame.coefficientCount <= policy.maximumCoefficientBytes / 4,
              policy.maximumMemoryBytes >= fixed,
              frame.coefficientCount <= (policy.maximumMemoryBytes - fixed) / 8 else {
            throw JPEGEntropyError.resourceLimit
        }
        admittedBytes = fixed + frame.coefficientCount * 8
        for ci in 0..<count {
            let component = frame.components[ci]
            let (blocks, overflow) = component.paddedBlocksWide.multipliedReportingOverflow(by: component.paddedBlocksHigh)
            let (values, valuesOverflow) = blocks.multipliedReportingOverflow(by: 64)
            guard !overflow, !valuesOverflow, coefficients[ci].count == values,
                  quantisation[ci].count == 64, quantisation[ci].allSatisfy({ $0 != 0 }) else {
                throw JPEGEntropyError.malformed
            }
            guard (1...2).contains(component.horizontalSampling),
                  (1...2).contains(component.verticalSampling) else { throw JPEGEntropyError.unsupported }
        }
        if count == 3 {
            // Match the predecessor's qualified 444/422/420/440 envelope.
            for ci in 1..<3 {
                guard frame.components[ci].horizontalSampling == 1,
                      frame.components[ci].verticalSampling == 1 else { throw JPEGEntropyError.unsupported }
            }
            // JXL only signals chroma subsampling with the YCbCr transform.
            if colourTransform == .none {
                guard frame.components[0].horizontalSampling == 1,
                      frame.components[0].verticalSampling == 1 else { throw JPEGEntropyError.unsupported }
            }
        } else {
            guard frame.components[0].horizontalSampling == 1,
                  frame.components[0].verticalSampling == 1 else { throw JPEGEntropyError.unsupported }
        }
        let mapping = count == 1 ? [0, 0, 0] : (colourTransform == .yCbCr ? [1, 0, 2] : [0, 1, 2])
        var channels: [Channel] = []
        var modes: [UInt32] = []
        var quant = [Int32](repeating: 0, count: 192)
        var dc: [Float] = []
        for c in 0..<3 {
            let ci = mapping[c], component = frame.components[ci]
            let zero = count == 1 && c != 1
            let offset: Int32 = colourTransform == .none && !zero ? 1024 / Int32(quantisation[ci][0]) : 0
            channels.append(Channel(jpegComponent: zero ? nil : ci,
                blocksWide: component.paddedBlocksWide, blocksHigh: component.paddedBlocksHigh,
                visibleBlocksWide: component.visibleBlocksWide, visibleBlocksHigh: component.visibleBlocksHigh,
                dcOffset: offset))
            switch (component.horizontalSampling, component.verticalSampling) {
            case (1, 1): modes.append(0)
            case (2, 2): modes.append(1)
            case (2, 1): modes.append(2)
            case (1, 2): modes.append(3)
            default: throw JPEGEntropyError.unsupported
            }
            dc.append(2040 / Float(quantisation[ci][0]))
            for y in 0..<8 {
                for x in 0..<8 { quant[c * 64 + 8 * x + y] = Int32(quantisation[ci][8 * y + x]) }
            }
        }
        self.frame = frame; self.colourTransform = colourTransform
        self.chromaSubsampling = YCbCrChromaSubsampling(y: modes[0], cb: modes[1], cr: modes[2])
        self.channels = channels; self.sourceCoefficients = coefficients
        self.quantisation = quant; self.dcQuantisation = dc; self.policy = policy
        try policy.checkpoint()
    }

    /// Populate one caller-owned block in JXL natural order. Position zero is
    /// the adjusted integer DC; AC positions are transposed. The frame writer
    /// must code DC separately. Scratch must have exactly 64 elements and be
    /// exclusively owned to avoid a caller-induced copy-on-write allocation.
    package func readBlock(channel: Int, block: Int, into scratch: inout [Int32]) throws {
        try policy.checkpoint()
        guard (0..<3).contains(channel), scratch.count == 64 else { throw JPEGEntropyError.malformed }
        let layout = channels[channel]
        guard block >= 0, block < layout.blocksWide * layout.blocksHigh else { throw JPEGEntropyError.malformed }
        if let ci = layout.jpegComponent {
            let base = block * 64
            let (dc, overflow) = sourceCoefficients[ci][base].addingReportingOverflow(layout.dcOffset)
            guard !overflow else { throw JPEGEntropyError.malformed }
            for y in 0..<8 {
                for x in 0..<8 { scratch[y * 8 + x] = sourceCoefficients[ci][base + x * 8 + y] }
            }
            scratch[0] = dc
        } else {
            for i in 0..<64 { scratch[i] = 0 }
        }
    }

    package func dc(channel: Int, block: Int) throws -> Int32 {
        try policy.checkpoint()
        guard (0..<3).contains(channel) else { throw JPEGEntropyError.malformed }
        let layout = channels[channel]
        guard block >= 0, block < layout.blocksWide * layout.blocksHigh else { throw JPEGEntropyError.malformed }
        guard let ci = layout.jpegComponent else { return 0 }
        let (value, overflow) = sourceCoefficients[ci][block * 64].addingReportingOverflow(layout.dcOffset)
        guard !overflow else { throw JPEGEntropyError.malformed }
        return value
    }
}
