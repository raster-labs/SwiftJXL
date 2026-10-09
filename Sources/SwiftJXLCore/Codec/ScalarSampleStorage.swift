// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
import Foundation

/// Algorithm access to samples. The core visits only indices in `0..<count`,
/// reading neighbours that were initialised earlier in this decode operation.
/// A conformer must retain its allocation for the whole synchronous operation.
package protocol ModularSampleBuffer {
    var count: Int { get }
    subscript(index: Int) -> Int32 { get set }
}

extension Array: ModularSampleBuffer where Element == Int32 {}

/// Checked byte geometry for a single unsigned 16-bit plane. Meaningful bits
/// remain low-aligned; neither padding nor gaps between samples are addressed.
package struct ScalarPlaneLayout: Sendable {
    package let width: Int
    package let height: Int
    package let offset: Int
    package let rowBytes: Int
    package let pixelStride: Int
    package let littleEndian: Bool
    package let requiredBytes: Int

    package init(width: Int, height: Int, offset: Int = 0, rowBytes: Int,
                 pixelStride: Int = 2, littleEndian: Bool = true) throws {
        guard width > 0, height > 0, width <= 1024, height <= 1024,
              offset >= 0, pixelStride >= 2, rowBytes >= 2 else {
            throw ScalarModularError.invalidInput("Invalid scalar plane geometry")
        }
        func multiply(_ a: Int, _ b: Int) throws -> Int {
            let (value, overflow) = a.multipliedReportingOverflow(by: b)
            guard !overflow else { throw ScalarModularError.resourceLimit }
            return value
        }
        func add(_ a: Int, _ b: Int) throws -> Int {
            let (value, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw ScalarModularError.resourceLimit }
            return value
        }
        let payload = try add(multiply(width - 1, pixelStride), 2)
        guard rowBytes >= payload else { throw ScalarModularError.invalidInput("Overlapping scalar rows") }
        self.requiredBytes = try add(offset, add(multiply(height - 1, rowBytes), payload))
        self.width = width; self.height = height; self.offset = offset
        self.rowBytes = rowBytes; self.pixelStride = pixelStride; self.littleEndian = littleEndian
    }
}

extension ScalarModularFrame {
    /// Caller must retain an exclusive mutable borrow for this synchronous call.
    /// The buffer and any pointer into it are neither retained nor passed to a worker.
    package func decode(into bytes: UnsafeMutableRawBufferPointer, layout: ScalarPlaneLayout) throws {
        guard layout.width == width, layout.height == height, bytes.count >= layout.requiredBytes else {
            throw ScalarModularError.invalidInput("Scalar destination does not match the frame")
        }
        var plane = BorrowedScalarPlane(bytes: bytes, layout: layout)
        try decode(into: &plane)
    }
}

/// Exists only within the synchronous borrow above; intentionally not Sendable.
private struct BorrowedScalarPlane: ModularSampleBuffer {
    let bytes: UnsafeMutableRawBufferPointer
    let layout: ScalarPlaneLayout
    var count: Int { layout.width * layout.height }
    subscript(index: Int) -> Int32 {
        get {
            let offset = layout.offset + (index / layout.width) * layout.rowBytes
                + (index % layout.width) * layout.pixelStride
            let first = Int32(bytes[offset]), second = Int32(bytes[offset + 1])
            return layout.littleEndian ? first | (second << 8) : (first << 8) | second
        }
        set {
            let offset = layout.offset + (index / layout.width) * layout.rowBytes
                + (index % layout.width) * layout.pixelStride
            let low = UInt8(truncatingIfNeeded: newValue), high = UInt8(truncatingIfNeeded: newValue >> 8)
            // The decode loop has checked sample precision before this write.
            bytes[offset] = layout.littleEndian ? low : high
            bytes[offset + 1] = layout.littleEndian ? high : low
        }
    }
}

package enum ScalarModularEncoder {
    /// Reads a retained synchronous source borrow directly into the codec's Int32
    /// working plane (four bytes per sample). This is algorithm workspace, not
    /// a packed UInt16 staging image. The caller must account for that workspace;
    /// it is not a measurement of the encoder's total peak workspace.
    package static func encode(_ bytes: UnsafeRawBufferPointer, layout: ScalarPlaneLayout,
                               bitsPerSample: Int, renderingIntent: RenderingIntent = .relative, budget: ScalarOperationBudget? = nil) throws -> Data {
        if let budget {
            let limit = try budget.admitEncoder(width: layout.width, height: layout.height)
            let work = ScalarEncodingWork(budget: budget, writerByteLimit: limit)
            return try ScalarEncodingWork.$current.withValue(work) {
                let result = try encode(bytes, layout: layout, bitsPerSample: bitsPerSample, renderingIntent: renderingIntent)
                try work.checkpoint()
                return result
            }
        }
        try Task.checkCancellation()
        guard (9...16).contains(bitsPerSample), layout.width <= 512, layout.height <= 512 else {
            throw ScalarModularError.unsupportedProfile
        }
        guard bytes.count >= layout.requiredBytes else {
            throw ScalarModularError.invalidInput("Scalar source is shorter than its declared geometry")
        }
        let maximum = (Int32(1) << bitsPerSample) - 1
        ScalarStorageAudit.current?.workingPlane(layout.width * layout.height * MemoryLayout<Int32>.stride)
        var working = [Int32](repeating: 0, count: layout.width * layout.height)
        for y in 0..<layout.height {
            try ScalarEncodingWork.checkpoint()
            for x in 0..<layout.width {
                let position = layout.offset + y * layout.rowBytes + x * layout.pixelStride
                let first = Int32(bytes[position]), second = Int32(bytes[position + 1])
                let sample = layout.littleEndian ? first | (second << 8) : (first << 8) | second
                guard sample <= maximum else {
                    throw ScalarModularError.invalidInput("Source sample exceeds meaningful precision")
                }
                working[y * layout.width + x] = sample
            }
        }
        return try SpecModularEncoder.encodeGrayscale16(width: layout.width, height: layout.height,
            bitsPerSample: UInt32(bitsPerSample), pixelsInt32: working, effort: 3, renderingIntent: renderingIntent)
    }
}
