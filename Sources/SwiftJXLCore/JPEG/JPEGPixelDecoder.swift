// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Adapted from the pixel pipeline of JXLSwift JPEGDecoder/JPEGIDCT/
// JPEGColorConversion at 57e81cb9e2411d1efac435b429a306a031744c1e.
// Uses the already bounded coefficient parser; ITU-T T.81 A.3.3 separable IDCT.
import Foundation

/// Explicit, bounded JPEG pixel convenience path. This is distinct from
/// original-bitstream reconstruction. The caller declares sRGB interpretation;
/// embedded ICC/Exif interpretation must never be discarded or guessed here.
package struct JPEGPixelFrame: Sendable {
    package let source: Data
    package let frame: JPEGFrameLayout
    package let budget: ScalarOperationBudget
    private let rgb: Bool
    private let coefficientWorkspace: Int

    package init(_ source: Data, budget: ScalarOperationBudget,
                 maximumDimension: Int, maximumPixels: Int, maximumMetadataBytes: Int,
                 discardAncillary: Bool) throws {
        try budget.checkpoint()
        guard source.count <= min(budget.maximumCompressedBytes, 64 * 1024 * 1024) else {
            throw JPEGEntropyError.resourceLimit
        }
        var reader = try JPEGSegmentReader(source, maximumInputBytes: budget.maximumCompressedBytes,
            deadline: budget.deadline, checkpoint: { try budget.checkpoint() })
        var found: JPEGFrameLayout?, adobe: UInt8?, ancillary = 0
        while let segment = try reader.next() {
            try budget.checkpoint()
            if (0xc0...0xcf).contains(segment.markerByte), ![UInt8(0xc4), 0xc8, 0xcc].contains(segment.markerByte) {
                guard found == nil else { throw JPEGEntropyError.unsupported }
                let value = try JPEGFrameLayout(data: source, segment: segment, maximumCoefficientBytes: 64 * 1024 * 1024)
                guard value.width <= min(maximumDimension, 2048), value.height <= min(maximumDimension, 2048),
                      value.width <= maximumPixels / value.height else { throw JPEGEntropyError.resourceLimit }
                found = value
            }
            if (0xe0...0xef).contains(segment.markerByte) || segment.markerByte == 0xfe {
                ancillary = try ScalarOperationBudget.sum(ancillary, segment.payloadRange.count)
                guard ancillary <= maximumMetadataBytes else { throw JPEGEntropyError.resourceLimit }
                func begins(_ text: String) -> Bool {
                    let prefix = Array(text.utf8), range = segment.payloadRange
                    return range.count >= prefix.count && prefix.enumerated().allSatisfy {
                        source[source.startIndex + range.lowerBound + $0.offset] == $0.element
                    }
                }
                // Exif may require orientation/colour processing; ICC defines
                // colour. Neither is ancillary for this explicit pixel route.
                if segment.markerByte == 0xe1 || (segment.markerByte == 0xe2 && begins("ICC_PROFILE\0")) {
                    throw JPEGEntropyError.unsupported
                }
                if segment.markerByte == 0xee && begins("Adobe") {
                    guard segment.payloadRange.count == 12, adobe == nil else { throw JPEGEntropyError.malformed }
                    adobe = source[source.startIndex + segment.payloadRange.lowerBound + 11]
                    guard adobe == 0 || adobe == 1 else { throw JPEGEntropyError.unsupported }
                } else if !(segment.markerByte == 0xe0 && begins("JFIF\0")), !discardAncillary {
                    throw JPEGEntropyError.unsupported
                }
            }
        }
        guard let frame = found, let tail = reader.trailingRange else { throw JPEGEntropyError.malformed }
        guard tail.count <= maximumMetadataBytes - ancillary else { throw JPEGEntropyError.resourceLimit }
        guard tail.isEmpty || discardAncillary else { throw JPEGEntropyError.unsupported }
        let ids = frame.components.map(\.id)
        let rgb = frame.components.count == 3 && (adobe == 0 || ids == [82, 71, 66])
        if frame.components.count == 3 {
            guard ids == [1, 2, 3] || ids == [82, 71, 66] else { throw JPEGEntropyError.unsupported }
            guard !(ids == [82, 71, 66] && adobe == 1) else { throw JPEGEntropyError.unsupported }
            let first = frame.components[0]
            guard frame.components.dropFirst().allSatisfy({ $0.horizontalSampling == 1 && $0.verticalSampling == 1 }),
                  (1...2).contains(first.horizontalSampling), (1...2).contains(first.verticalSampling),
                  !rgb || (first.horizontalSampling == 1 && first.verticalSampling == 1) else {
                throw JPEGEntropyError.unsupported
            }
        }
        // Parser capacity overlap, Huffman/history, bounded reconstruction
        // events and component planes are algorithm workspace, not handoff copies.
        let coefficients = try ScalarOperationBudget.product(frame.coefficientCount, 8)
        let coefficientWorkspace = try ScalarOperationBudget.sum(coefficients, 20 * 1024 * 1024)
        try budget.reserveWorkspace(ScalarOperationBudget.sum(coefficientWorkspace,
            ScalarOperationBudget.sum(ScalarOperationBudget.product(frame.coefficientCount, 2), 64 * 1024)))
        self.source = source; self.frame = frame; self.budget = budget
        self.rgb = rgb; self.coefficientWorkspace = coefficientWorkspace
    }

    /// Writes the final samples directly into the one scoped destination borrow.
    /// No pointer escapes. Components remain at native sampling resolution.
    package func decode(into bytes: UnsafeMutableRawBufferPointer, layouts: [ModularChannelLayout]) throws {
        guard layouts.count == frame.components.count,
              layouts.allSatisfy({ $0.width == frame.width && $0.height == frame.height && $0.requiredBytes <= bytes.count }) else {
            throw JPEGEntropyError.malformed
        }
        let decoded = try JPEGCoefficientDecoder.decode(source, policy: .init(
            maximumInputBytes: min(budget.maximumCompressedBytes, 64 * 1024 * 1024),
            maximumCoefficientBytes: 64 * 1024 * 1024,
            maximumMemoryBytes: ScalarOperationBudget.sum(coefficientWorkspace, source.count),
            deadline: budget.deadline, checkpoint: { try budget.checkpoint() }))
        var planes: [[UInt8]] = []
        var temporary = [Double](repeating: 0, count: 64)
        for (c, component) in frame.components.enumerated() {
            let width = component.paddedBlocksWide * 8, height = component.paddedBlocksHigh * 8
            ScalarStorageAudit.current?.workingPlane(width * height)
            var plane = [UInt8](repeating: 0, count: width * height)
            for by in 0..<component.paddedBlocksHigh {
                for bx in 0..<component.paddedBlocksWide {
                    try budget.checkpoint()
                    let base = (by * component.paddedBlocksWide + bx) * 64
                    for v in 0..<8 {
                        for x in 0..<8 {
                            var sum = 0.0
                            for u in 0..<8 {
                                sum += Double(decoded.coefficients[c][base + v * 8 + u]) * Double(decoded.quantisation[c][v * 8 + u]) * Self.basis[x * 8 + u]
                            }
                            temporary[v * 8 + x] = sum
                        }
                    }
                    for y in 0..<8 {
                        for x in 0..<8 {
                            var sum = 0.0
                            for v in 0..<8 { sum += temporary[v * 8 + x] * Self.basis[y * 8 + v] }
                            plane[(by * 8 + y) * width + bx * 8 + x] = Self.clamp(sum.rounded(.toNearestOrAwayFromZero) + 128)
                        }
                    }
                }
            }
            planes.append(plane)
        }
        let maxH = frame.components.map(\.horizontalSampling).max() ?? 1
        let maxV = frame.components.map(\.verticalSampling).max() ?? 1
        for y in 0..<frame.height {
            try budget.checkpoint()
            for x in 0..<frame.width {
                func sample(_ c: Int) -> Double {
                    let component = frame.components[c]
                    return Double(planes[c][(y * component.verticalSampling / maxV) * component.paddedBlocksWide * 8
                        + x * component.horizontalSampling / maxH])
                }
                let first = sample(0)
                for c in layouts.indices {
                    let value: Double
                    if planes.count == 1 { value = first }
                    else if rgb { value = sample(c) }
                    else {
                        let cb = sample(1) - 128, cr = sample(2) - 128
                        value = c == 0 ? first + 1.402 * cr : c == 1 ? first - 0.344136 * cb - 0.714136 * cr : first + 1.772 * cb
                    }
                    let layout = layouts[c], p = layout.offset + y * layout.rowBytes + x * layout.pixelStride
                    let low = Self.clamp(value)
                    if layout.storageBits == 8 { bytes[p] = low }
                    else { bytes[p] = layout.littleEndian ? low : 0; bytes[p + 1] = layout.littleEndian ? 0 : low }
                }
            }
        }
        try budget.checkpoint()
    }
    private static func clamp(_ value: Double) -> UInt8 {
        UInt8(min(255, max(0, value.rounded(.toNearestOrAwayFromZero))))
    }
    private static let basis: [Double] = (0..<64).map { i in
        let x = i / 8, u = i % 8
        return (u == 0 ? 1 / sqrt(8.0) : 0.5) * cos(Double((2 * x + 1) * u) * Double.pi / 16)
    }
}
