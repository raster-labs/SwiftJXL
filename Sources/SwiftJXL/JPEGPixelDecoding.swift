// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXLCore

/// The source's decoded grey/RGB samples are explicitly interpreted as sRGB.
/// This is a caller declaration, not an inferred profile or colour conversion.
public enum JPEGPixelInterpretation: Sendable { case srgb }

extension Decoder {
    /// Separate convenience profile; the ordinary decode method remains JPEG XL.
    /// 8-bit Huffman DCT, one/three components, at most 2048 per dimension.
    /// Nearest chroma upsampling, scalar IDCT and full-range BT.601 YCbCr→RGB.
    /// ICC/Exif, CMYK, 12-bit, SOF3 and arithmetic inputs reject. Use Transcoder
    /// for byte-exact restoration of an existing JPEG instead of pixel decoding.
    public static let jpegPixelCapabilities = CodecCapabilities(formats: ["jpeg"], compressionModes: [.lossy],
        sampleTypes: [.unsignedInteger], meaningfulPrecision: 8...8, layouts: ["interleaved", "planar"],
        availableBackends: [.scalarCPU], canInspect: true, canEncode: false, canDecode: true)

    public func inspectJPEG(_ data: Data, interpretingAs: JPEGPixelInterpretation,
                            options: DecodeOptions = .init()) throws -> ImageInfo {
        try jpegPixelErrors {
            let context = try JPEGPixelContext(data, options: options, start: .now)
            return ImageInfo(format: "jpeg", descriptor: try context.descriptor(), frameCount: 1, metadata: .empty)
        }
    }

    @concurrent public func decodeJPEG(_ data: Data, interpretingAs: JPEGPixelInterpretation,
                                       options: DecodeOptions = .init()) async throws -> DecodedImage {
        let start = ContinuousClock.now
        return try jpegPixelErrors {
            let context = try JPEGPixelContext(data, options: options, start: start)
            let descriptor = try context.descriptor()
            try context.frame.budget.reservePixels(descriptor.requiredByteCount)
            let destination = try ImageDestination.allocate(descriptor: descriptor, limits: options.resourceLimits)
            return try context.finish(into: destination, start: start, allocated: true)
        }
    }

    @concurrent public func decodeJPEG(_ data: Data, interpretingAs: JPEGPixelInterpretation,
                                       into destination: ImageDestination,
                                       options: DecodeOptions = .init()) async throws -> DecodedImage {
        let start = ContinuousClock.now
        return try jpegPixelErrors {
            try JPEGPixelContext(data, options: options, start: start).finish(into: destination, start: start, allocated: false)
        }
    }
}

private struct JPEGPixelContext {
    let frame: JPEGPixelFrame
    let options: DecodeOptions
    var roles: [ComponentRole] { frame.frame.components.count == 1 ? [.grey] : [.red, .green, .blue] }
    init(_ data: Data, options: DecodeOptions, start: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        if case .required(.accelerated) = options.executionPolicy {
            throw CodecError(.backendUnavailable, "JPEG pixel decoding requires the scalar backend.")
        }
        let limits = options.resourceLimits
        let budget = try ScalarOperationBudget(retainedBytes: data.count,
            maximumWorkspaceBytes: limits.maximumWorkspaceBytes, maximumMemoryBytes: limits.maximumMemoryBytes,
            maximumDecodedBytes: limits.maximumDecodedBytes, maximumCompressedBytes: limits.maximumCompressedBytes,
            deadline: start.advanced(by: .seconds(min(limits.deadlineSeconds, 31_536_000))))
        frame = try JPEGPixelFrame(data, budget: budget, maximumDimension: limits.maximumDimension,
            maximumPixels: limits.maximumPixels, maximumMetadataBytes: limits.maximumMetadataBytes,
            discardAncillary: options.metadataPolicy == .discardAncillary)
        self.options = options
    }
    func descriptor() throws -> ImageDescriptor {
        let f = frame.frame, count = roles.count
        let row = try checkedMultiply(f.width, count), capacity = try checkedMultiply(row, f.height)
        let plane = try PlaneDescriptor(width: f.width, height: f.height, components: Array(roles.indices),
            sampleStride: 1, pixelStride: count, rowBytes: row, byteCount: capacity)
        return try ImageDescriptor(width: f.width, height: f.height, storageBits: 8, meaningfulBits: 8,
            components: roles, colour: count == 1 ? .greyscale : .rgb, planes: [plane], limits: options.resourceLimits)
    }
    func finish(into destination: ImageDestination, start: ContinuousClock.Instant, allocated: Bool) throws -> DecodedImage {
        let d = destination.descriptor, budget = frame.budget
        try d.validate(limits: options.resourceLimits)
        guard d.width == frame.frame.width, d.height == frame.frame.height, d.sampleType == .unsignedInteger,
              d.meaningfulBits == 8, d.alpha == .absent, d.iccProfile == nil,
              d.colour == (roles.count == 1 ? .greyscale : .rgb),
              d.components.count == roles.count, roles.allSatisfy({ d.components.contains($0) }) else {
            throw CodecError(.incompatibleImageLayout, "JPEG destination interpretation differs from the decoded frame.")
        }
        let layouts = try channelLayouts(d, roles: roles)
        try budget.reservePixels(destination.storage.byteCount)
        options.progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: 1))
        try budget.checkpoint()
        let image = try destination.write(metadata: .empty, beforeSeal: {
            try budget.checkpoint()
            options.progress?(try ProgressUpdate(phase: .completed, completedUnits: 1, totalUnits: 1))
            try budget.checkpoint()
        }) { bytes in try frame.decode(into: bytes, layouts: layouts) }
        let elapsed = start.duration(to: .now).components
        let fallback: String? = if case .preferred(.accelerated) = options.executionPolicy {
            "Accelerated backend unavailable; used scalar CPU."
        } else { nil }
        return .init(image: image, report: .init(backend: .scalarCPU, fallbackReason: fallback, fidelity: .lossy,
            pixelAllocationCount: allocated ? 1 : 0,
            elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18))
    }
}

private func jpegPixelErrors<T>(_ body: () throws -> T) throws -> T {
    do { return try body() }
    catch is CancellationError { throw CancellationError() }
    catch let error as CodecError { throw error }
    catch JPEGEntropyError.resourceLimit { throw jpegPixelLimit }
    catch JPEGFrameError.resourceLimit { throw jpegPixelLimit }
    catch JPEGParseError.resourceLimit { throw jpegPixelLimit }
    catch ScalarModularError.resourceLimit { throw jpegPixelLimit }
    catch JPEGEntropyError.unsupported { throw jpegPixelProfile }
    catch JPEGFrameError.unsupported { throw jpegPixelProfile }
    catch { throw CodecError(.malformedInput, "Invalid JPEG pixel input.") }
}
private var jpegPixelLimit: CodecError { .init(.resourceLimitExceeded, "JPEG pixel operation exceeded its resource or deadline limit.") }
private var jpegPixelProfile: CodecError { .init(.unsupportedFeature, "Input is outside the bounded JPEG pixel profile.") }
