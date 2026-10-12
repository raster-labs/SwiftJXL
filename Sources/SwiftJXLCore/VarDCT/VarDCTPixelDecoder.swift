// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Internal scalar pixel integration. Public capability remains separately gated
/// by profile, fidelity, ownership and interoperability qualification.
package enum VarDCTPixelDecoder {
    /// Writes encoded sRGB samples with explicit nearest-integer conversion,
    /// preserving the frame's meaningful precision and exact unassociated alpha.
    /// The caller retains an exclusive synchronous borrow of non-overlapping
    /// component storage and must discard/poison that owner if this call throws.
    /// No pointer escapes and no task or worker outlives the borrow. Padding is
    /// untouched; this function never allocates a second packed pixel image.
    package static func decode(_ envelope: VarDCTFrameEnvelope,
                               into bytes: UnsafeMutableRawBufferPointer,
                               layouts: [ModularChannelLayout]) throws {
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
        let planes = try VarDCTReconstruction.xyb(coefficients)
        let maximum = Double((1 << bits) - 1)
        var destination = layouts.map { BorrowedModularChannel(bytes: bytes, layout: $0) }
        for y in 0..<envelope.height {
            try budget.checkpoint()
            for x in 0..<envelope.width {
                if x & 255 == 0 { try budget.checkpoint() }
                let i = y * envelope.width + x
                let rgb = try DefaultOpsin.inverse((X: Double(planes[0][i]),
                    Y: Double(planes[1][i]), B: Double(planes[2][i])))
                destination[0][i] = encodeSRGB(rgb.R, maximum: maximum)
                if !grayscale {
                    destination[1][i] = encodeSRGB(rgb.G, maximum: maximum)
                    destination[2][i] = encodeSRGB(rgb.B, maximum: maximum)
                }
                if let values = coefficients.alpha { destination[colours][i] = values[i] }
            }
        }
        try budget.checkpoint()
    }

    private static func encodeSRGB(_ linear: Double, maximum: Double) -> Int32 {
        // Clipping here is the explicit bounded integer output representation,
        // following reconstruction in the codestream's declared sRGB space.
        let bounded = min(1, max(0, linear))
        let encoded = bounded <= 0.0031308 ? 12.92 * bounded
            : 1.055 * pow(bounded, 1 / 2.4) - 0.055
        return Int32((min(1, max(0, encoded)) * maximum).rounded())
    }
}
