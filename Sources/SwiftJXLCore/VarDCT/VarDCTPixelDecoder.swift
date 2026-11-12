// SPDX-License-Identifier: MIT
import Foundation

/// Internal scalar pixel integration. Public capability remains separately gated
/// by profile, fidelity, ownership and interoperability qualification.
package enum VarDCTPixelDecoder {
    /// Writes encoded sRGB samples with the explicitly selected numerical mode,
    /// preserving the frame's meaningful precision and exact unassociated alpha.
    /// The caller retains an exclusive synchronous borrow of non-overlapping
    /// component storage and must discard/poison that owner if this call throws.
    /// No pointer escapes and no task or worker outlives the borrow. Padding is
    /// untouched; this function never allocates a second packed pixel image.
    package static func decode(_ envelope: VarDCTFrameEnvelope,
                               into bytes: UnsafeMutableRawBufferPointer,
                               layouts: [ModularChannelLayout],
                               numericalMode: VarDCTNumericalMode = .scalarNearest) throws {
        let budget = envelope.budget
        try budget.checkpoint()
        // XYB may be reconstructed independently of its original ICC profile,
        // but publishing sRGB integers would change that interpretation.
        guard !envelope.metadata.colorEncoding.useICC else { throw ScalarModularError.unsupportedProfile }
        let grayscale = envelope.metadata.colorEncoding.colorSpace == .grayscale
        let colours = grayscale ? 1 : 3
        let alpha = envelope.metadata.extraChannels.first
        guard alpha?.alphaAssociated != true else { throw ScalarModularError.unsupportedProfile }
        let bits = Int(envelope.metadata.bitDepth.bitsPerSample)
        guard layouts.count == colours + (alpha == nil ? 0 : 1),
              layouts.allSatisfy({ $0.width == envelope.width && $0.height == envelope.height &&
                  $0.storageBits >= bits && $0.requiredBytes <= bytes.count }) else {
            throw ScalarModularError.invalidInput("VarDCT destination does not match frame")
        }
        try budget.reservePixels(bytes.count)
        try budget.reserveWorkspace(1024) // at most four borrowed channel descriptors
        let coefficients = try VarDCTCoefficients.read(envelope)
        let planes = try VarDCTReconstruction.xyb(coefficients, numericalMode: numericalMode)
        let maximum = Double((1 << bits) - 1)
        let destination = layouts.map { BorrowedModularChannel(bytes: bytes, layout: $0) }
        let width = envelope.width, height = envelope.height
        let dst0 = destination[0]
        let dst1 = grayscale ? dst0 : destination[1]
        let dst2 = grayscale ? dst0 : destination[2]
        let dstAlpha = coefficients.alpha != nil ? destination[colours] : dst0
        try planes[0].withUnsafeBufferPointer { b0 in
            try planes[1].withUnsafeBufferPointer { b1 in
                try planes[2].withUnsafeBufferPointer { b2 in
                    let p0 = b0.baseAddress!, p1 = b1.baseAddress!, p2 = b2.baseAddress!
                    if bits == 8 && numericalMode == .scalarNearest && coefficients.alpha == nil {
                        let tables = srgb8Tables
                        let threshPtr = tables.thresholds
                        let bucketPtr = tables.bucketK
                        let rawBase = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        let workers = min(max(1, budget.maximumWorkers), 8)
                        if !grayscale,
                           layouts[0].rowBytes == layouts[1].rowBytes, layouts[1].rowBytes == layouts[2].rowBytes,
                           layouts[0].pixelStride == layouts[1].pixelStride, layouts[1].pixelStride == layouts[2].pixelStride {
                            let rowBytes = layouts[0].rowBytes
                            if layouts[0].storageBits == 8, layouts[1].storageBits == 8, layouts[2].storageBits == 8,
                               layouts[0].pixelStride == 3,
                               layouts[0].offset == 0, layouts[1].offset == 1, layouts[2].offset == 2 {
                                if workers > 1 && height >= 64 {
                                    try budget.checkpoint()
                                    let bandCount = min(workers, height)
                                    nonisolated(unsafe) let uRawBase = rawBase
                                    nonisolated(unsafe) let uP0 = p0, uP1 = p1, uP2 = p2
                                    nonisolated(unsafe) let uThresh = threshPtr, uBucket = bucketPtr
                                    DispatchQueue.concurrentPerform(iterations: bandCount) { band in
                                        let y0 = (band * height) / bandCount
                                        let y1 = ((band + 1) * height) / bandCount
                                        for y in y0..<y1 {
                                            let rowOffset = y &* width
                                            var dstPos = y &* rowBytes
                                            for x in 0..<width {
                                                let i = rowOffset &+ x
                                                let rgb = DefaultOpsin.inverseUnchecked(Double(uP0[i]), Double(uP1[i]), Double(uP2[i]))
                                                uRawBase[dstPos] = encodeSRGB8Byte(rgb.R, thresholds: uThresh, bucketK: uBucket)
                                                uRawBase[dstPos &+ 1] = encodeSRGB8Byte(rgb.G, thresholds: uThresh, bucketK: uBucket)
                                                uRawBase[dstPos &+ 2] = encodeSRGB8Byte(rgb.B, thresholds: uThresh, bucketK: uBucket)
                                                dstPos &+= 3
                                            }
                                        }
                                    }
                                } else {
                                    for y in 0..<height {
                                        if (y & 15) == 0 { try budget.checkpoint() }
                                        let rowOffset = y &* width
                                        var dstPos = y &* rowBytes
                                        for x in 0..<width {
                                            let i = rowOffset &+ x
                                            let rgb = DefaultOpsin.inverseUnchecked(Double(p0[i]), Double(p1[i]), Double(p2[i]))
                                            rawBase[dstPos] = encodeSRGB8Byte(rgb.R, thresholds: threshPtr, bucketK: bucketPtr)
                                            rawBase[dstPos &+ 1] = encodeSRGB8Byte(rgb.G, thresholds: threshPtr, bucketK: bucketPtr)
                                            rawBase[dstPos &+ 2] = encodeSRGB8Byte(rgb.B, thresholds: threshPtr, bucketK: bucketPtr)
                                            dstPos &+= 3
                                        }
                                    }
                                }
                                try budget.checkpoint()
                                return
                            } else if layouts[0].storageBits == 16, layouts[1].storageBits == 16, layouts[2].storageBits == 16,
                                      layouts[0].littleEndian, layouts[1].littleEndian, layouts[2].littleEndian,
                                      layouts[0].pixelStride == 6,
                                      layouts[0].offset == 0, layouts[1].offset == 2, layouts[2].offset == 4 {
                                if workers > 1 && height >= 64 {
                                    try budget.checkpoint()
                                    let bandCount = min(workers, height)
                                    nonisolated(unsafe) let uRawBase = rawBase
                                    nonisolated(unsafe) let uP0 = p0, uP1 = p1, uP2 = p2
                                    nonisolated(unsafe) let uThresh = threshPtr, uBucket = bucketPtr
                                    DispatchQueue.concurrentPerform(iterations: bandCount) { band in
                                        let y0 = (band * height) / bandCount
                                        let y1 = ((band + 1) * height) / bandCount
                                        for y in y0..<y1 {
                                            let rowOffset = y &* width
                                            var dstPos = y &* rowBytes
                                            for x in 0..<width {
                                                let i = rowOffset &+ x
                                                let rgb = DefaultOpsin.inverseUnchecked(Double(uP0[i]), Double(uP1[i]), Double(uP2[i]))
                                                uRawBase[dstPos] = encodeSRGB8Byte(rgb.R, thresholds: uThresh, bucketK: uBucket)
                                                uRawBase[dstPos &+ 1] = 0
                                                uRawBase[dstPos &+ 2] = encodeSRGB8Byte(rgb.G, thresholds: uThresh, bucketK: uBucket)
                                                uRawBase[dstPos &+ 3] = 0
                                                uRawBase[dstPos &+ 4] = encodeSRGB8Byte(rgb.B, thresholds: uThresh, bucketK: uBucket)
                                                uRawBase[dstPos &+ 5] = 0
                                                dstPos &+= 6
                                            }
                                        }
                                    }
                                } else {
                                    for y in 0..<height {
                                        if (y & 15) == 0 { try budget.checkpoint() }
                                        let rowOffset = y &* width
                                        var dstPos = y &* rowBytes
                                        for x in 0..<width {
                                            let i = rowOffset &+ x
                                            let rgb = DefaultOpsin.inverseUnchecked(Double(p0[i]), Double(p1[i]), Double(p2[i]))
                                            rawBase[dstPos] = encodeSRGB8Byte(rgb.R, thresholds: threshPtr, bucketK: bucketPtr)
                                            rawBase[dstPos &+ 1] = 0
                                            rawBase[dstPos &+ 2] = encodeSRGB8Byte(rgb.G, thresholds: threshPtr, bucketK: bucketPtr)
                                            rawBase[dstPos &+ 3] = 0
                                            rawBase[dstPos &+ 4] = encodeSRGB8Byte(rgb.B, thresholds: threshPtr, bucketK: bucketPtr)
                                            rawBase[dstPos &+ 5] = 0
                                            dstPos &+= 6
                                        }
                                    }
                                }
                                try budget.checkpoint()
                                return
                            }
                        } else if grayscale, layouts[0].offset == 0 {
                            let rowBytes = layouts[0].rowBytes
                            if layouts[0].storageBits == 8, layouts[0].pixelStride == 1 {
                                if workers > 1 && height >= 64 {
                                    try budget.checkpoint()
                                    let bandCount = min(workers, height)
                                    nonisolated(unsafe) let uRawBase = rawBase
                                    nonisolated(unsafe) let uP0 = p0, uP1 = p1, uP2 = p2
                                    nonisolated(unsafe) let uThresh = threshPtr, uBucket = bucketPtr
                                    DispatchQueue.concurrentPerform(iterations: bandCount) { band in
                                        let y0 = (band * height) / bandCount
                                        let y1 = ((band + 1) * height) / bandCount
                                        for y in y0..<y1 {
                                            let rowOffset = y &* width
                                            let dstRow = y &* rowBytes
                                            for x in 0..<width {
                                                let i = rowOffset &+ x
                                                let rgb = DefaultOpsin.inverseUnchecked(Double(uP0[i]), Double(uP1[i]), Double(uP2[i]))
                                                uRawBase[dstRow &+ x] = encodeSRGB8Byte(rgb.R, thresholds: uThresh, bucketK: uBucket)
                                            }
                                        }
                                    }
                                } else {
                                    for y in 0..<height {
                                        if (y & 15) == 0 { try budget.checkpoint() }
                                        let rowOffset = y &* width
                                        let dstRow = y &* rowBytes
                                        for x in 0..<width {
                                            let i = rowOffset &+ x
                                            let rgb = DefaultOpsin.inverseUnchecked(Double(p0[i]), Double(p1[i]), Double(p2[i]))
                                            rawBase[dstRow &+ x] = encodeSRGB8Byte(rgb.R, thresholds: threshPtr, bucketK: bucketPtr)
                                        }
                                    }
                                }
                                try budget.checkpoint()
                                return
                            } else if layouts[0].storageBits == 16, layouts[0].littleEndian, layouts[0].pixelStride == 2 {
                                if workers > 1 && height >= 64 {
                                    try budget.checkpoint()
                                    let bandCount = min(workers, height)
                                    nonisolated(unsafe) let uRawBase = rawBase
                                    nonisolated(unsafe) let uP0 = p0, uP1 = p1, uP2 = p2
                                    nonisolated(unsafe) let uThresh = threshPtr, uBucket = bucketPtr
                                    DispatchQueue.concurrentPerform(iterations: bandCount) { band in
                                        let y0 = (band * height) / bandCount
                                        let y1 = ((band + 1) * height) / bandCount
                                        for y in y0..<y1 {
                                            let rowOffset = y &* width
                                            var dstPos = y &* rowBytes
                                            for x in 0..<width {
                                                let i = rowOffset &+ x
                                                let rgb = DefaultOpsin.inverseUnchecked(Double(uP0[i]), Double(uP1[i]), Double(uP2[i]))
                                                uRawBase[dstPos] = encodeSRGB8Byte(rgb.R, thresholds: uThresh, bucketK: uBucket)
                                                uRawBase[dstPos &+ 1] = 0
                                                dstPos &+= 2
                                            }
                                        }
                                    }
                                } else {
                                    for y in 0..<height {
                                        if (y & 15) == 0 { try budget.checkpoint() }
                                        let rowOffset = y &* width
                                        var dstPos = y &* rowBytes
                                        for x in 0..<width {
                                            let i = rowOffset &+ x
                                            let rgb = DefaultOpsin.inverseUnchecked(Double(p0[i]), Double(p1[i]), Double(p2[i]))
                                            rawBase[dstPos] = encodeSRGB8Byte(rgb.R, thresholds: threshPtr, bucketK: bucketPtr)
                                            rawBase[dstPos &+ 1] = 0
                                            dstPos &+= 2
                                        }
                                    }
                                }
                                try budget.checkpoint()
                                return
                            }
                        }
                    }
                    for y in 0..<height {
                        try budget.checkpoint()
                        let rowOffset = y &* width
                        let r0 = dst0.rowAddress(y, width: width)
                        let r1 = grayscale ? 0 : dst1.rowAddress(y, width: width)
                        let r2 = grayscale ? 0 : dst2.rowAddress(y, width: width)
                        let rAlpha = coefficients.alpha != nil ? dstAlpha.rowAddress(y, width: width) : 0
                        for x in 0..<width {
                            if x & 255 == 0 { try budget.checkpoint() }
                            let i = rowOffset &+ x
                            let rgb = try DefaultOpsin.inverse((X: Double(p0[i]),
                                Y: Double(p1[i]), B: Double(p2[i])))
                            dst0[row: r0, column: x] = encodeSRGB(rgb.R, maximum: maximum, bits: bits, x: x, y: y,
                                channel: 0, numericalMode: numericalMode)
                            if !grayscale {
                                dst1[row: r1, column: x] = encodeSRGB(rgb.G, maximum: maximum, bits: bits, x: x, y: y,
                                    channel: 1, numericalMode: numericalMode)
                                dst2[row: r2, column: x] = encodeSRGB(rgb.B, maximum: maximum, bits: bits, x: x, y: y,
                                    channel: 2, numericalMode: numericalMode)
                            }
                            if let values = coefficients.alpha { dstAlpha[row: rAlpha, column: x] = values[i] }
                        }
                    }
                }
            }
        }
        try budget.checkpoint()
    }

    // Exact IEEE-754 threshold table for 8-bit scalarNearest sRGB encoding.
    // Because 1/4096 < 1/(255 * 12.92), each linear bucket Int(linear * 4096.0)
    // spans at most one threshold, mapping to k or k + 1 with a single comparison and zero pow()/sqrt() calls.
    nonisolated(unsafe) private static let srgb8Tables: (thresholds: UnsafePointer<Double>, bucketK: UnsafePointer<UInt8>) = {
        let threshPtr = UnsafeMutablePointer<Double>.allocate(capacity: 256)
        for k in 0..<255 {
            var lo = (0.0).bitPattern
            var hi = (1.0).bitPattern
            while lo &+ 1 < hi {
                let midBits = lo &+ ((hi &- lo) >> 1)
                let mid = Double(bitPattern: midBits)
                let enc = mid <= 0.0031308 ? 12.92 * mid : 1.055 * pow(mid, 1.0 / 2.4) - 0.055
                let q = Int32((min(1.0, max(0.0, enc)) * 255.0).rounded())
                if q <= Int32(k) {
                    lo = midBits
                } else {
                    hi = midBits
                }
            }
            threshPtr[k] = Double(bitPattern: hi)
        }
        threshPtr[255] = Double.infinity

        let bucketPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: 4097)
        for b in 0...4096 {
            let linLo = Double(b) / 4096.0
            let enc = linLo <= 0.0031308 ? 12.92 * linLo : 1.055 * pow(linLo, 1.0 / 2.4) - 0.055
            let q = Int(min(254, max(0, Int32((min(1.0, max(0.0, enc)) * 255.0).rounded()))))
            bucketPtr[b] = UInt8(q)
        }
        return (UnsafePointer(threshPtr), UnsafePointer(bucketPtr))
    }()

    @inline(__always)
    private static func encodeSRGB8Byte(_ linear: Double,
                                        thresholds: UnsafePointer<Double>,
                                        bucketK: UnsafePointer<UInt8>) -> UInt8 {
        if linear <= 0.0 { return 0 }
        if linear >= 1.0 { return 255 }
        let b = Int(linear * 4096.0)
        let k = Int(bucketK[b])
        return linear >= thresholds[k] ? UInt8(truncatingIfNeeded: k &+ 1) : UInt8(truncatingIfNeeded: k)
    }

    @inline(__always)
    private static func encodeSRGB8ScalarNearest(_ linear: Double,
                                                 thresholds: UnsafePointer<Double>,
                                                 bucketK: UnsafePointer<UInt8>) -> Int32 {
        Int32(encodeSRGB8Byte(linear, thresholds: thresholds, bucketK: bucketK))
    }

    @inline(__always)
    private static func encodeSRGB(_ linear: Double, maximum: Double, bits: Int,
                                   x: Int, y: Int, channel: Int,
                                   numericalMode: VarDCTNumericalMode) -> Int32 {
        if bits == 8 && numericalMode == .scalarNearest {
            let tables = srgb8Tables
            return encodeSRGB8ScalarNearest(linear, thresholds: tables.thresholds, bucketK: tables.bucketK)
        }
        // Clipping here is the explicit bounded integer output representation,
        // following reconstruction in the codestream's declared sRGB space.
        let bounded = min(1, max(0, linear))
        let encoded = bounded <= 0.0031308 ? 12.92 * bounded
            : 1.055 * pow(bounded, 1 / 2.4) - 0.055
        if numericalMode == .libjxl012ARMInteger {
            return VarDCTReferenceNumerics.integer(encoded, bits: bits, x: x, y: y, channel: channel)
        }
        return Int32((min(1, max(0, encoded)) * maximum).rounded())
    }
}
