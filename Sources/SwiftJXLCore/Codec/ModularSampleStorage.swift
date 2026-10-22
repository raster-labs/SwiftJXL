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
    let base: UnsafeMutablePointer<UInt8>
    let layout: ModularChannelLayout
    init(bytes: UnsafeMutableRawBufferPointer, layout: ModularChannelLayout) {
        self.bytes = bytes
        self.base = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
        self.layout = layout
    }
    var count: Int { layout.width * layout.height }
    @inline(__always)
    func rowAddress(_ y: Int, width: Int) -> Int { layout.offset + y * layout.rowBytes }

    // Decode loops calculate each row address once. This avoids division and
    // remainder for every neighbour while preserving the same scoped borrow.
    @inline(__always)
    subscript(row row: Int, column column: Int) -> Int32 {
        get {
            let p = row &+ column &* layout.pixelStride
            let first = Int32(base[p])
            if layout.storageBits == 8 { return first }
            let second = Int32(base[p &+ 1])
            return layout.littleEndian ? first | (second &<< 8) : (first &<< 8) | second
        }
        nonmutating set {
            let p = row &+ column &* layout.pixelStride
            let low = UInt8(truncatingIfNeeded: newValue)
            if layout.storageBits == 8 { base[p] = low; return }
            let high = UInt8(truncatingIfNeeded: newValue &>> 8)
            if layout.littleEndian {
                base[p] = low
                base[p &+ 1] = high
            } else {
                base[p] = high
                base[p &+ 1] = low
            }
        }
    }
    subscript(index: Int) -> Int32 {
        get { self[row: rowAddress(index / layout.width, width: layout.width), column: index % layout.width] }
        nonmutating set { self[row: rowAddress(index / layout.width, width: layout.width), column: index % layout.width] = newValue }
    }
}

struct BorrowedModularChannel8: ModularSampleBuffer {
    let base: UnsafeMutablePointer<UInt8>
    let width: Int
    let height: Int
    let offset: Int
    let rowBytes: Int
    let pixelStride: Int

    init(bytes: UnsafeMutableRawBufferPointer, layout: ModularChannelLayout) {
        self.base = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
        self.width = layout.width
        self.height = layout.height
        self.offset = layout.offset
        self.rowBytes = layout.rowBytes
        self.pixelStride = layout.pixelStride
    }
    var count: Int { width * height }
    @inline(__always)
    func rowAddress(_ y: Int, width: Int) -> Int { offset &+ y &* rowBytes }
    @inline(__always)
    subscript(row row: Int, column column: Int) -> Int32 {
        get { Int32(base[row &+ column &* pixelStride]) }
        nonmutating set { base[row &+ column &* pixelStride] = UInt8(truncatingIfNeeded: newValue) }
    }
    subscript(index: Int) -> Int32 {
        get { self[row: rowAddress(index / width, width: width), column: index % width] }
        nonmutating set { self[row: rowAddress(index / width, width: width), column: index % width] = newValue }
    }
}

struct BorrowedModularChannel16LE: ModularSampleBuffer {
    let raw: UnsafeMutableRawPointer
    let width: Int
    let height: Int
    let offset: Int
    let rowBytes: Int
    let pixelStride: Int

    init(bytes: UnsafeMutableRawBufferPointer, layout: ModularChannelLayout) {
        self.raw = bytes.baseAddress!
        self.width = layout.width
        self.height = layout.height
        self.offset = layout.offset
        self.rowBytes = layout.rowBytes
        self.pixelStride = layout.pixelStride
    }
    var count: Int { width * height }
    @inline(__always)
    func rowAddress(_ y: Int, width: Int) -> Int { offset &+ y &* rowBytes }
    @inline(__always)
    subscript(row row: Int, column column: Int) -> Int32 {
        get {
            let p = row &+ column &* pixelStride
            return Int32(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: p, as: UInt16.self)))
        }
        nonmutating set {
            let p = row &+ column &* pixelStride
            raw.storeBytes(of: UInt16(truncatingIfNeeded: newValue).littleEndian, toByteOffset: p, as: UInt16.self)
        }
    }
    subscript(index: Int) -> Int32 {
        get { self[row: rowAddress(index / width, width: width), column: index % width] }
        nonmutating set { self[row: rowAddress(index / width, width: width), column: index % width] = newValue }
    }
}

struct BorrowedModularChannel16LEContiguous: ModularSampleBuffer {
    let raw: UnsafeMutableRawPointer
    let width: Int
    let height: Int
    let offset: Int
    let rowBytes: Int

    init(bytes: UnsafeMutableRawBufferPointer, layout: ModularChannelLayout) {
        self.raw = bytes.baseAddress!
        self.width = layout.width
        self.height = layout.height
        self.offset = layout.offset
        self.rowBytes = layout.rowBytes
    }
    var count: Int { width * height }
    @inline(__always)
    func rowAddress(_ y: Int, width: Int) -> Int { offset &+ y &* rowBytes }
    @inline(__always)
    subscript(row row: Int, column column: Int) -> Int32 {
        get {
            let p = row &+ (column &<< 1)
            return Int32(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: p, as: UInt16.self)))
        }
        nonmutating set {
            let p = row &+ (column &<< 1)
            raw.storeBytes(of: UInt16(truncatingIfNeeded: newValue).littleEndian, toByteOffset: p, as: UInt16.self)
        }
    }
    subscript(index: Int) -> Int32 {
        get { self[row: rowAddress(index / width, width: width), column: index % width] }
        nonmutating set { self[row: rowAddress(index / width, width: width), column: index % width] = newValue }
    }
}

package enum ModularStorageEncoder {
    /// Source ownership and read borrow remain with the public caller. Only
    /// admitted signed algorithm planes are allocated; no packed source copy.
    package static func encode(_ bytes: UnsafeRawBufferPointer, layouts: [ModularChannelLayout],
                               bitsPerSample: Int, grayscale: Bool, alphaAssociated: Bool?,
                               renderingIntent: RenderingIntent, transferFunction: TransferFunction = .srgb, budget: ScalarOperationBudget) throws -> Data {
        guard let first = layouts.first, (8...16).contains(bitsPerSample),
              layouts.count == (grayscale ? 1 : 3) + (alphaAssociated == nil ? 0 : 1),
              layouts.allSatisfy({ $0.width == first.width && $0.height == first.height &&
                  $0.storageBits >= bitsPerSample && $0.requiredBytes <= bytes.count }) else {
            throw ScalarModularError.invalidInput("Incompatible Modular source layout")
        }
        let limit = try budget.admitModularEncoder(width: first.width, height: first.height, channels: layouts.count)
        return try ScalarEncodingWork.$current.withValue(.init(budget: budget, writerByteLimit: limit)) {
            let width = first.width, height = first.height
            let n = width * height, maximum = (Int32(1) << bitsPerSample) - 1
            let rowStep = max(1, 4096 / max(1, width))
            var channels: [[Int32]] = []
            channels.reserveCapacity(layouts.count)
            let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for layout in layouts {
                ScalarStorageAudit.current?.workingPlane(n * 4)
                var plane = [Int32](repeating: 0, count: n)
                try plane.withUnsafeMutableBufferPointer { dst in
                    let dstBase = dst.baseAddress!
                    let stride = layout.pixelStride
                    if layout.storageBits == 8 {
                        for y in 0..<height {
                            if y % rowStep == 0 { try ScalarEncodingWork.checkpoint() }
                            var p = layout.offset &+ y &* layout.rowBytes
                            let dstRow = y &* width
                            if bitsPerSample >= 8 {
                                for x in 0..<width {
                                    if width > 4096 && x > 0 && (x & 4095 == 0) { try ScalarEncodingWork.checkpoint() }
                                    dstBase[dstRow &+ x] = Int32(rawBase[p])
                                    p &+= stride
                                }
                            } else {
                                for x in 0..<width {
                                    if width > 4096 && x > 0 && (x & 4095 == 0) { try ScalarEncodingWork.checkpoint() }
                                    let value = Int32(rawBase[p])
                                    guard value <= maximum else { throw ScalarModularError.invalidInput("Source sample exceeds meaningful precision") }
                                    dstBase[dstRow &+ x] = value
                                    p &+= stride
                                }
                            }
                        }
                    } else if layout.littleEndian {
                        for y in 0..<height {
                            if y % rowStep == 0 { try ScalarEncodingWork.checkpoint() }
                            var p = layout.offset &+ y &* layout.rowBytes
                            let dstRow = y &* width
                            for x in 0..<width {
                                if width > 4096 && x > 0 && (x & 4095 == 0) { try ScalarEncodingWork.checkpoint() }
                                let value = Int32(rawBase[p]) | (Int32(rawBase[p &+ 1]) &<< 8)
                                guard value <= maximum else { throw ScalarModularError.invalidInput("Source sample exceeds meaningful precision") }
                                dstBase[dstRow &+ x] = value
                                p &+= stride
                            }
                        }
                    } else {
                        for y in 0..<height {
                            if y % rowStep == 0 { try ScalarEncodingWork.checkpoint() }
                            var p = layout.offset &+ y &* layout.rowBytes
                            let dstRow = y &* width
                            for x in 0..<width {
                                if width > 4096 && x > 0 && (x & 4095 == 0) { try ScalarEncodingWork.checkpoint() }
                                let value = (Int32(rawBase[p]) &<< 8) | Int32(rawBase[p &+ 1])
                                guard value <= maximum else { throw ScalarModularError.invalidInput("Source sample exceeds meaningful precision") }
                                dstBase[dstRow &+ x] = value
                                p &+= stride
                            }
                        }
                    }
                }
                channels.append(plane)
            }
            let data = try SpecModularEncoder.encodeInteger(width: width, height: height,
                bitsPerSample: bitsPerSample, grayscale: grayscale, alphaAssociated: alphaAssociated,
                channels: channels, renderingIntent: renderingIntent, transferFunction: transferFunction)
            try ScalarEncodingWork.checkpoint()
            return data
        }
    }
}
