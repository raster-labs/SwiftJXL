// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Adapted from the pixel pipeline of JXLSwift JPEGDecoder/JPEGIDCT/
// JPEGColorConversion at 57e81cb9e2411d1efac435b429a306a031744c1e.
// Uses the already bounded coefficient parser; ITU-T T.81 A.3.3 separable IDCT.
import Foundation

/// Explicit, bounded JPEG pixel convenience path. This is distinct from
/// original-bitstream reconstruction. Colour and Exif orientation choices are
/// explicit; embedded interpretation is never discarded or guessed here.
package struct JPEGPixelFrame: Sendable {
    package let source: Data
    package let frame: JPEGFrameLayout
    package let budget: ScalarOperationBudget
    package let metadata: JPEGPixelMetadata
    package let hasPointTransform: Bool
    private let rgb: Bool
    private let coefficientWorkspace: Int

    package init(_ source: Data, budget: ScalarOperationBudget,
                 maximumDimension: Int, maximumPixels: Int, maximumMetadataBytes: Int,
                 maximumICCBytes: Int, maximumNestingDepth: Int, embeddedInterpretation: Bool,
                 discardAncillary: Bool) throws {
        try budget.checkpoint()
        guard source.count <= min(budget.maximumCompressedBytes, 64 * 1024 * 1024) else {
            throw JPEGEntropyError.resourceLimit
        }
        // Admit fixed parser/Huffman and metadata-record capacity before
        // collecting frame components or up to 255 ICC fragment ranges.
        // This is the same allowance formerly charged after metadata parsing.
        try budget.reserveWorkspace(64 * 1024)
        var reader = try JPEGSegmentReader(source, maximumInputBytes: budget.maximumCompressedBytes,
            deadline: budget.deadline, checkpoint: { try budget.checkpoint() })
        var found: JPEGFrameLayout?, adobe: UInt8?, ancillary = 0
        var metadata = JPEGPixelMetadata(), hasPointTransform = false
        while let segment = try reader.next() {
            try budget.checkpoint()
            if (0xc0...0xcf).contains(segment.markerByte), ![UInt8(0xc4), 0xc8, 0xcc].contains(segment.markerByte) {
                guard found == nil else { throw JPEGEntropyError.unsupported }
                let value = try JPEGFrameLayout(data: source, segment: segment, maximumCoefficientBytes: 64 * 1024 * 1024, pixelProfile: true)
                guard value.width <= min(maximumDimension, 2048), value.height <= min(maximumDimension, 2048),
                      value.width <= maximumPixels / value.height else { throw JPEGEntropyError.resourceLimit }
                found = value
            }
            if segment.markerByte == 0xda, found?.marker == 0xc3 {
                guard segment.payloadRange.count >= 6 else { throw JPEGEntropyError.malformed }
                let point = source[source.startIndex + segment.payloadRange.upperBound - 1]
                guard let f = found, point < f.precision else { throw JPEGEntropyError.malformed }
                hasPointTransform = hasPointTransform || point != 0
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
                if segment.markerByte == 0xe1 && begins("Exif\0\0") {
                    guard embeddedInterpretation else { throw JPEGEntropyError.unsupported }
                    let r = segment.payloadRange
                    try budget.reserveWorkspace(ScalarOperationBudget.product(r.count, 2))
                    try metadata.addExif(Data(source[(source.startIndex + r.lowerBound)..<(source.startIndex + r.upperBound)]),
                        maximumDepth: maximumNestingDepth, budget: budget)
                    continue
                }
                if segment.markerByte == 0xe2 && begins("ICC_PROFILE\0") {
                    guard embeddedInterpretation else { throw JPEGEntropyError.unsupported }
                    try metadata.addICC(segment.payloadRange, source: source, maximumBytes: min(maximumICCBytes, 4 * 1024 * 1024))
                    continue
                }
                if segment.markerByte == 0xee && begins("Adobe") {
                    guard segment.payloadRange.count == 12, adobe == nil else { throw JPEGEntropyError.malformed }
                    adobe = source[source.startIndex + segment.payloadRange.lowerBound + 11]
                    guard adobe == 0 || adobe == 1 else { throw JPEGEntropyError.unsupported }
                } else if !(segment.markerByte == 0xe0 && begins("JFIF\0")) {
                    guard discardAncillary else { throw JPEGEntropyError.unsupported }
                    try metadata.recordDiscard(marker: segment.markerByte, payloadBytes: segment.payloadRange.count, budget: budget)
                }
            }
        }
        guard let frame = found, let tail = reader.trailingRange else { throw JPEGEntropyError.malformed }
        guard tail.count <= maximumMetadataBytes - ancillary else { throw JPEGEntropyError.resourceLimit }
        guard tail.isEmpty || discardAncillary else { throw JPEGEntropyError.unsupported }
        if !tail.isEmpty { try metadata.recordDiscard(marker: nil, payloadBytes: tail.count, budget: budget) }
        metadata.finishDiscardSummary()
        try metadata.finishICC(source: source, components: frame.components.count, budget: budget)
        if embeddedInterpretation && metadata.iccProfile == nil && !metadata.exifSRGB { throw JPEGEntropyError.unsupported }
        let ids = frame.components.map(\.id)
        let rgb = frame.components.count == 3 && (frame.marker == 0xc3 || adobe == 0 || ids == [82, 71, 66])
        if frame.marker == 0xc3, adobe == 1 { throw JPEGEntropyError.unsupported }
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
        let coefficientWorkspace: Int
        if frame.marker == 0xc3 {
            // One Int predictor row per component, plus array capacity overlap
            // and fixed parser/Huffman buffers; no full decoded-image scratch.
            coefficientWorkspace = 0
            try budget.reserveWorkspace(ScalarOperationBudget.product(
                ScalarOperationBudget.product(frame.width, frame.components.count), 32))
        } else {
            let coefficients = try ScalarOperationBudget.product(frame.coefficientCount, 8)
            coefficientWorkspace = try ScalarOperationBudget.sum(coefficients, 20 * 1024 * 1024)
            try budget.reserveWorkspace(ScalarOperationBudget.sum(coefficientWorkspace,
                ScalarOperationBudget.product(frame.coefficientCount, 2)))
        }
        self.source = source; self.frame = frame; self.budget = budget
        self.rgb = rgb; self.coefficientWorkspace = coefficientWorkspace
        self.metadata = metadata; self.hasPointTransform = hasPointTransform
    }

    /// Writes the final samples directly into the one scoped destination borrow.
    /// No pointer escapes. Components remain at native sampling resolution.
    package func decode(into bytes: UnsafeMutableRawBufferPointer, layouts: [ModularChannelLayout], orientation: Int = 1) throws {
        let outputWidth = orientation >= 5 ? frame.height : frame.width
        let outputHeight = orientation >= 5 ? frame.width : frame.height
        guard (1...8).contains(orientation), layouts.count == frame.components.count,
              layouts.allSatisfy({ $0.width == outputWidth && $0.height == outputHeight && $0.requiredBytes <= bytes.count }) else {
            throw JPEGEntropyError.malformed
        }
        if frame.marker == 0xc3 {
            try JPEGLosslessPixelDecoder.decode(source, frame: frame, budget: budget,
                into: bytes, layouts: layouts, orientation: orientation)
            return
        }
        let decoded = try JPEGCoefficientDecoder.decode(source, policy: .init(pixelProfile: true,
            maximumInputBytes: min(budget.maximumCompressedBytes, 64 * 1024 * 1024),
            maximumCoefficientBytes: 64 * 1024 * 1024,
            maximumMemoryBytes: ScalarOperationBudget.sum(coefficientWorkspace, source.count),
            deadline: budget.deadline, checkpoint: { try budget.checkpoint() }))
        // Preserve the existing byte-sized 8-bit component workspace. Only
        // 12-bit input uses UInt16 planes; the generic loop specialises at these
        // two concrete call sites without a per-sample storage-kind branch.
        if frame.precision == 8 {
            try decodeDCT(decoded, into: bytes, layouts: layouts, orientation: orientation, sampleType: UInt8.self)
        } else {
            try decodeDCT(decoded, into: bytes, layouts: layouts, orientation: orientation, sampleType: UInt16.self)
        }
    }
    private func decodeDCT<Sample: FixedWidthInteger & UnsignedInteger>(
        _ decoded: JPEGDecodedCoefficients, into bytes: UnsafeMutableRawBufferPointer,
        layouts: [ModularChannelLayout], orientation: Int, sampleType: Sample.Type) throws {
        // Private dispatch above proves the sample type represents this maximum.
        let maximum = (1 << frame.precision) - 1, midpoint = Double(1 << (frame.precision - 1))
        var planes: [[Sample]] = []
        var temporary = [Double](repeating: 0, count: 64)
        for (c, component) in frame.components.enumerated() {
            let width = component.paddedBlocksWide * 8, height = component.paddedBlocksHigh * 8
            ScalarStorageAudit.current?.workingPlane(width * height * MemoryLayout<Sample>.stride)
            var plane = [Sample](repeating: 0, count: width * height)
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
                            plane[(by * 8 + y) * width + bx * 8 + x] = Sample(Self.clamp(sum.rounded(.toNearestOrAwayFromZero) + midpoint, maximum: maximum))
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
                    let stride = component.paddedBlocksWide * 8
                    return Double(planes[c][(y * component.verticalSampling / maxV) * stride
                        + x * component.horizontalSampling / maxH])
                }
                let first = sample(0)
                for c in layouts.indices {
                    let value: Double
                    if planes.count == 1 { value = first }
                    else if rgb { value = sample(c) }
                    else {
                        let cb = sample(1) - midpoint, cr = sample(2) - midpoint
                        value = c == 0 ? first + 1.402 * cr : c == 1 ? first - 0.344136 * cb - 0.714136 * cr : first + 1.772 * cb
                    }
                    let (dx, dy) = Self.destinationPosition(x: x, y: y, width: frame.width,
                        height: frame.height, orientation: orientation)
                    let layout = layouts[c], p = layout.offset + dy * layout.rowBytes + dx * layout.pixelStride
                    let sample = Self.clamp(value, maximum: maximum), low = UInt8(truncatingIfNeeded: sample), high = UInt8(sample >> 8)
                    if layout.storageBits == 8 { bytes[p] = low }
                    else { bytes[p] = layout.littleEndian ? low : high; bytes[p + 1] = layout.littleEndian ? high : low }
                }
            }
        }
        try budget.checkpoint()
    }
    package static func destinationPosition(x: Int, y: Int, width: Int, height: Int,
                                            orientation: Int) -> (Int, Int) {
        switch orientation {
        case 2: (width - 1 - x, y)
        case 3: (width - 1 - x, height - 1 - y)
        case 4: (x, height - 1 - y)
        case 5: (y, x)
        case 6: (height - 1 - y, x)
        case 7: (height - 1 - y, width - 1 - x)
        case 8: (y, width - 1 - x)
        default: (x, y)
        }
    }
    private static func clamp(_ value: Double, maximum: Int) -> UInt16 {
        UInt16(min(Double(maximum), max(0, value.rounded(.toNearestOrAwayFromZero))))
    }
    private static let basis: [Double] = (0..<64).map { i in
        let x = i / 8, u = i % 8
        return (u == 0 ? 1 / sqrt(8.0) : 0.5) * cos(Double((2 * x + 1) * u) * Double.pi / 16)
    }
}
