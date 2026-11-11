// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
import Foundation

/// Algorithm access to samples. The core visits only indices in `0..<count`,
/// reading neighbours that were initialised earlier in this decode operation.
/// A conformer must retain its allocation for the whole synchronous operation.
package protocol ModularSampleBuffer {
    var count: Int { get }
    subscript(index: Int) -> Int32 { get set }
    /// An opaque row address valid only with this buffer's row/column accessor.
    /// Callers provide validated geometry and never access padding as samples.
    func rowAddress(_ y: Int, width: Int) -> Int
    subscript(row row: Int, column column: Int) -> Int32 { get set }
}

extension ModularSampleBuffer {
    @inline(__always)
    package func rowAddress(_ y: Int, width: Int) -> Int { y * width }
    @inline(__always)
    package subscript(row row: Int, column column: Int) -> Int32 {
        get { self[row + column] }
        set { self[row + column] = newValue }
    }
}

extension Array: ModularSampleBuffer where Element == Int32 {}
extension UnsafeMutableBufferPointer: ModularSampleBuffer where Element == Int32 {}

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
    let base: UnsafeMutablePointer<UInt8>
    let layout: ScalarPlaneLayout
    init(bytes: UnsafeMutableRawBufferPointer, layout: ScalarPlaneLayout) {
        self.bytes = bytes
        self.base = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
        self.layout = layout
    }
    var count: Int { layout.width * layout.height }
    @inline(__always)
    func rowAddress(_ y: Int, width: Int) -> Int { layout.offset &+ y &* layout.rowBytes }
    @inline(__always)
    subscript(row row: Int, column column: Int) -> Int32 {
        get {
            let offset = row &+ column &* layout.pixelStride
            let first = Int32(base[offset]), second = Int32(base[offset &+ 1])
            return layout.littleEndian ? first | (second &<< 8) : (first &<< 8) | second
        }
        nonmutating set {
            let offset = row &+ column &* layout.pixelStride
            let low = UInt8(truncatingIfNeeded: newValue), high = UInt8(truncatingIfNeeded: newValue &>> 8)
            // The decode loop has checked sample precision before this write.
            if layout.littleEndian {
                base[offset] = low
                base[offset &+ 1] = high
            } else {
                base[offset] = high
                base[offset &+ 1] = low
            }
        }
    }
    subscript(index: Int) -> Int32 {
        get { self[row: rowAddress(index / layout.width, width: layout.width), column: index % layout.width] }
        nonmutating set { self[row: rowAddress(index / layout.width, width: layout.width), column: index % layout.width] = newValue }
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
        let width = layout.width, height = layout.height
        ScalarStorageAudit.current?.workingPlane(width * height * MemoryLayout<Int32>.stride)
        var working = [Int32](repeating: 0, count: width * height)
        let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let stride = layout.pixelStride
        try working.withUnsafeMutableBufferPointer { dst in
            let dstBase = dst.baseAddress!
            if layout.littleEndian {
                for y in 0..<height {
                    try ScalarEncodingWork.checkpoint()
                    var position = layout.offset &+ y &* layout.rowBytes
                    let dstRow = y &* width
                    for x in 0..<width {
                        let sample = Int32(rawBase[position]) | (Int32(rawBase[position &+ 1]) &<< 8)
                        guard sample <= maximum else {
                            throw ScalarModularError.invalidInput("Source sample exceeds meaningful precision")
                        }
                        dstBase[dstRow &+ x] = sample
                        position &+= stride
                    }
                }
            } else {
                for y in 0..<height {
                    try ScalarEncodingWork.checkpoint()
                    var position = layout.offset &+ y &* layout.rowBytes
                    let dstRow = y &* width
                    for x in 0..<width {
                        let sample = (Int32(rawBase[position]) &<< 8) | Int32(rawBase[position &+ 1])
                        guard sample <= maximum else {
                            throw ScalarModularError.invalidInput("Source sample exceeds meaningful precision")
                        }
                        dstBase[dstRow &+ x] = sample
                        position &+= stride
                    }
                }
            }
        }
        return try SpecModularEncoder.encodeGrayscale16(width: width, height: height,
            bitsPerSample: UInt32(bitsPerSample), pixelsInt32: working, effort: 3, renderingIntent: renderingIntent)
    }
}
