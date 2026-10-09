// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One canonical channel in a validated planar or interleaved destination.
/// Component offsets are explicit; row padding is never treated as samples.
package struct ModularChannelLayout: Sendable {
    package let width: Int, height: Int, offset: Int, rowBytes: Int, pixelStride: Int
    package let storageBits: Int, littleEndian: Bool, requiredBytes: Int

    package init(width: Int, height: Int, offset: Int, rowBytes: Int,
                 pixelStride: Int, storageBits: Int, littleEndian: Bool) throws {
        guard (1...16384).contains(width), (1...16384).contains(height),
              storageBits == 8 || storageBits == 16, offset >= 0,
              pixelStride >= storageBits / 8 else {
            throw ScalarModularError.invalidInput("Invalid Modular channel layout")
        }
        let payload = try ScalarOperationBudget.sum(
            ScalarOperationBudget.product(width - 1, pixelStride), storageBits / 8)
        guard rowBytes >= payload else { throw ScalarModularError.invalidInput("Overlapping Modular rows") }
        requiredBytes = try ScalarOperationBudget.sum(offset,
            ScalarOperationBudget.sum(ScalarOperationBudget.product(height - 1, rowBytes), payload))
        self.width = width; self.height = height; self.offset = offset
        self.rowBytes = rowBytes; self.pixelStride = pixelStride
        self.storageBits = storageBits; self.littleEndian = littleEndian
    }

    package func rectangle(x: Int, y: Int, width: Int, height: Int) throws -> Self {
        guard x >= 0, y >= 0, width > 0, height > 0,
              x <= self.width - width, y <= self.height - height else {
            throw ScalarModularError.invalidInput("Invalid Modular destination rectangle")
        }
        return try Self(width: width, height: height, offset: offset + y * rowBytes + x * pixelStride,
                        rowBytes: rowBytes, pixelStride: pixelStride,
                        storageBits: storageBits, littleEndian: littleEndian)
    }
}

/// Synchronous borrow only: intentionally not Sendable and never retained in a
/// prepared frame. The owning API validates component non-overlap before entry.
struct BorrowedModularDestination {
    let bytes: UnsafeMutableRawBufferPointer
    let layouts: [ModularChannelLayout]
}

/// Predictor neighbours are read from samples already written during this
/// decode. The decode loop checks precision before writing a sample.
struct BorrowedModularChannel: ModularSampleBuffer {
    let bytes: UnsafeMutableRawBufferPointer
    let layout: ModularChannelLayout
    var count: Int { layout.width * layout.height }
    subscript(index: Int) -> Int32 {
        get {
            let p = layout.offset + (index / layout.width) * layout.rowBytes + (index % layout.width) * layout.pixelStride
            let first = Int32(bytes[p])
            if layout.storageBits == 8 { return first }
            let second = Int32(bytes[p + 1])
            return layout.littleEndian ? first | (second << 8) : (first << 8) | second
        }
        set {
            let p = layout.offset + (index / layout.width) * layout.rowBytes + (index % layout.width) * layout.pixelStride
            let low = UInt8(truncatingIfNeeded: newValue), high = UInt8(truncatingIfNeeded: newValue >> 8)
            if layout.storageBits == 8 { bytes[p] = low; return }
            bytes[p] = layout.littleEndian ? low : high
            bytes[p + 1] = layout.littleEndian ? high : low
        }
    }
}
