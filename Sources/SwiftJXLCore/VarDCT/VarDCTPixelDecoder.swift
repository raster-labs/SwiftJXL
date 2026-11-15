// SPDX-License-Identifier: MIT
import Dispatch
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
        let width = envelope.width, height = envelope.height
        let alphaValues = coefficients.alpha
        let outWorkers = min(max(1, budget.maximumWorkers), height >= 32 ? min(8, height) : 1)
        let dstAddr = Int(bitPattern: bytes.baseAddress!)
        let dstCount = bytes.count

        try planes[0].withUnsafeBufferPointer { b0 in
            try planes[1].withUnsafeBufferPointer { b1 in
                try planes[2].withUnsafeBufferPointer { b2 in
                    let p0Addr = Int(bitPattern: b0.baseAddress!)
                    let p1Addr = Int(bitPattern: b1.baseAddress!)
                    let p2Addr = Int(bitPattern: b2.baseAddress!)

                    @Sendable
                    func writeRows(_ yStart: Int, _ yEnd: Int) throws {
                        let localBytes = UnsafeMutableRawBufferPointer(
                            start: UnsafeMutableRawPointer(bitPattern: dstAddr),
                            count: dstCount
                        )
                        let destination = layouts.map { BorrowedModularChannel(bytes: localBytes, layout: $0) }
                        let dst0 = destination[0]
                        let dst1 = grayscale ? dst0 : destination[1]
                        let dst2 = grayscale ? dst0 : destination[2]
                        let dstAlpha = alphaValues != nil ? destination[colours] : dst0
                        let p0 = UnsafePointer<Float>(bitPattern: p0Addr)!
                        let p1 = UnsafePointer<Float>(bitPattern: p1Addr)!
                        let p2 = UnsafePointer<Float>(bitPattern: p2Addr)!

                        for y in yStart..<yEnd {
                            try budget.checkpoint()
                            let rowOffset = y &* width
                            let r0 = dst0.rowAddress(y, width: width)
                            let r1 = grayscale ? 0 : dst1.rowAddress(y, width: width)
                            let r2 = grayscale ? 0 : dst2.rowAddress(y, width: width)
                            let rAlpha = alphaValues != nil ? dstAlpha.rowAddress(y, width: width) : 0
                            if grayscale && alphaValues == nil && dst0.layout.storageBits == 16 &&
                               dst0.layout.littleEndian && dst0.layout.pixelStride == 2 {
                                let rowPtr = localBytes.baseAddress! + r0
                                for x in 0..<width {
                                    if x & 255 == 0 { try budget.checkpoint() }
                                    let i = rowOffset &+ x
                                    let rgb = try DefaultOpsin.inverse((X: Double(p0[i]), Y: Double(p1[i]), B: Double(p2[i])))
                                    let val = encodeSRGB(rgb.R, maximum: maximum, bits: bits, x: x, y: y,
                                        channel: 0, numericalMode: numericalMode)
                                    rowPtr.storeBytes(
                                        of: UInt16(truncatingIfNeeded: val).littleEndian,
                                        toByteOffset: x &<< 1,
                                        as: UInt16.self
                                    )
                                }
                            } else {
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
                                    if let values = alphaValues { dstAlpha[row: rAlpha, column: x] = values[i] }
                                }
                            }
                        }
                    }

                    if outWorkers <= 1 {
                        try writeRows(0, height)
                    } else {
                        let errMutex = PackageMutex<(any Error)?>(nil)
                        let rowsPerWorker = (height + outWorkers - 1) / outWorkers
                        DispatchQueue.concurrentPerform(iterations: outWorkers) { w in
                            let y0 = w * rowsPerWorker
                            let y1 = min(height, y0 + rowsPerWorker)
                            guard y0 < y1 else { return }
                            do {
                                try writeRows(y0, y1)
                            } catch {
                                errMutex.withLock { if $0 == nil { $0 = error } }
                            }
                        }
                        if let err = errMutex.withLock({ $0 }) { throw err }
                    }
                }
            }
        }
        try budget.checkpoint()
    }

    private static func encodeSRGB(_ linear: Double, maximum: Double, bits: Int,
                                   x: Int, y: Int, channel: Int,
                                   numericalMode: VarDCTNumericalMode) -> Int32 {
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
