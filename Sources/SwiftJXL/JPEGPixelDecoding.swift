// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXLCore

/// Explicit consent for Exif display orientation. No colour display transform occurs.
public enum JPEGExifOrientationPolicy: Sendable { case preserve, apply }

/// Colour interpretation is either a caller declaration or source metadata.
public enum JPEGPixelInterpretation: Sendable {
    /// Assert untagged sRGB grey/RGB. Embedded ICC/Exif require `.embedded`.
    case srgb
    /// Require embedded grey/RGB ICC or Exif sRGB; retain ICC exactly without
    /// conversion. Preserve or explicitly apply Exif orientation. Untagged input
    /// rejects. SOF3 components are stored grey/RGB, never implicitly YCbCr.
    case embedded(orientation: JPEGExifOrientationPolicy)
}

extension Decoder {
    /// Separate convenience profile; the ordinary decode method remains JPEG XL.
    /// 8/12-bit Huffman DCT and 2–16-bit SOF3, one/three components,
    /// at most 2048 per dimension. DCT uses nearest chroma upsampling, scalar
    /// IDCT and full-range BT.601 YCbCr→RGB. SOF3 requires full-resolution
    /// grey/stored RGB, supports all seven predictors and whole-row restarts.
    /// Nonzero SOF3 point transforms retain declared precision and zero low
    /// bits, reporting lossy fidelity; they cannot recover discarded source bits.
    /// ICC remains the descriptor's exact profile. Exif is required metadata:
    /// `jpeg.orientation` is the raster's orientation (one byte, 1–8),
    /// `jpeg.exif` retains original Exif when preserving orientation, including
    /// applying identity orientation 1. Applying a nonidentity orientation uses
    /// `jpeg.sourceExif` as unchanged source provenance and publishes orientation 1.
    /// No implicit profile conversion occurs.
    /// With `discardAncillary`, discarded unknown APPn/COM payloads and trailing
    /// data are reported in optional `jpeg.discardedAncillary` metadata as UTF-8
    /// JSON: `{"version":1,"items":[{"kind":"APP3","count":2,"payloadBytes":7}]}`.
    /// Kinds are APP0–APP15, COM and trailingData; counts and byte totals contain
    /// no discarded payload. Marker framing bytes are excluded. The report counts
    /// towards the metadata/resource limits; required ICC/Exif are never dropped.
    /// Use Transcoder for byte-exact JPEG restoration.
    public static let jpegPixelCapabilities = CodecCapabilities(formats: ["jpeg"], compressionModes: [.lossless, .lossy],
        sampleTypes: [.unsignedInteger], meaningfulPrecision: 2...16, layouts: ["interleaved", "planar"],
        availableBackends: [.scalarCPU], canInspect: true, canEncode: false, canDecode: true)

    public func inspectJPEG(_ data: Data, interpretingAs: JPEGPixelInterpretation,
                            options: DecodeOptions = .init()) throws -> ImageInfo {
        try jpegPixelErrors {
            let context = try JPEGPixelContext(data, interpretingAs: interpretingAs, options: options, start: .now)
            return ImageInfo(format: "jpeg", descriptor: try context.descriptor(), frameCount: 1, metadata: try context.imageMetadata())
        }
    }

    @concurrent public func decodeJPEG(_ data: Data, interpretingAs: JPEGPixelInterpretation,
                                       options: DecodeOptions = .init()) async throws -> DecodedImage {
        let start = ContinuousClock.now
        return try jpegPixelErrors {
            let context = try JPEGPixelContext(data, interpretingAs: interpretingAs, options: options, start: start)
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
            try destination.descriptor.validate(limits: options.resourceLimits)
            let context = try JPEGPixelContext(data, interpretingAs: interpretingAs, options: options, start: start,
                destinationBytes: destination.storage.byteCount,
                destinationMetadataBytes: destination.descriptor.iccProfile?.count ?? 0)
            return try context.finish(into: destination, start: start, allocated: false)
        }
    }
}

private struct JPEGPixelContext {
    let frame: JPEGPixelFrame
    let options: DecodeOptions
    let orientation: Int
    var width: Int { orientation >= 5 ? frame.frame.height : frame.frame.width }
    var height: Int { orientation >= 5 ? frame.frame.width : frame.frame.height }
    var roles: [ComponentRole] { frame.frame.components.count == 1 ? [.grey] : [.red, .green, .blue] }
    init(_ data: Data, interpretingAs: JPEGPixelInterpretation, options: DecodeOptions, start: ContinuousClock.Instant,
         destinationBytes: Int = 0, destinationMetadataBytes: Int = 0) throws {
        try Task.checkCancellation()
        if case .required(.accelerated) = options.executionPolicy {
            throw CodecError(.backendUnavailable, "JPEG pixel decoding requires the scalar backend.")
        }
        let limits = options.resourceLimits
        let budget = try ScalarOperationBudget(retainedBytes: checkedAdd(data.count, destinationMetadataBytes),
            maximumWorkspaceBytes: limits.maximumWorkspaceBytes, maximumMemoryBytes: limits.maximumMemoryBytes,
            maximumDecodedBytes: limits.maximumDecodedBytes, maximumCompressedBytes: limits.maximumCompressedBytes,
            deadline: start.advanced(by: .seconds(min(limits.deadlineSeconds, 31_536_000))))
        // The caller retains its complete allocation and descriptor profile
        // during parsing, including any padding beyond the logical raster.
        // Admit both before header/ICC/Exif allocations, not only at finish.
        try budget.reservePixels(destinationBytes)
        let embedded: Bool, applyOrientation: Bool
        switch interpretingAs {
        case .srgb: embedded = false; applyOrientation = false
        case .embedded(let policy): embedded = true; applyOrientation = policy == .apply
        }
        frame = try JPEGPixelFrame(data, budget: budget, maximumDimension: limits.maximumDimension,
            maximumPixels: limits.maximumPixels, maximumMetadataBytes: limits.maximumMetadataBytes,
            maximumICCBytes: limits.maximumICCBytes, maximumNestingDepth: limits.maximumNestingDepth,
            embeddedInterpretation: embedded, discardAncillary: options.metadataPolicy == .discardAncillary)
        orientation = applyOrientation ? frame.metadata.orientation : 1
        self.options = options
        _ = try imageMetadata()
    }
    func imageMetadata() throws -> ImageMetadata {
        var entries: [String: Data] = [:]
        if let exif = frame.metadata.sourceExif {
            entries[orientation == 1 ? "jpeg.exif" : "jpeg.sourceExif"] = exif
            entries["jpeg.orientation"] = Data([UInt8(orientation == 1 ? frame.metadata.orientation : 1)])
        }
        let required = Set(entries.keys)
        if let summary = frame.metadata.discardedAncillary { entries["jpeg.discardedAncillary"] = summary }
        let value = ImageMetadata(entries: entries, requiredKeys: required)
        _ = try value.validate(limits: options.resourceLimits, additionalBytes: frame.metadata.iccProfile?.count ?? 0)
        return value
    }
    func descriptor() throws -> ImageDescriptor {
        let bits = frame.frame.precision, count = roles.count, bytes = bits <= 8 ? 1 : 2
        let row = try checkedMultiply(width, checkedMultiply(count, bytes)), capacity = try checkedMultiply(row, height)
        let plane = try PlaneDescriptor(width: width, height: height, components: Array(roles.indices),
            sampleStride: bytes, pixelStride: count * bytes, rowBytes: row, byteCount: capacity)
        return try ImageDescriptor(width: width, height: height, storageBits: bytes * 8, meaningfulBits: bits,
            components: roles, colour: count == 1 ? .greyscale : .rgb, planes: [plane],
            iccProfile: frame.metadata.iccProfile, limits: options.resourceLimits)
    }
    func finish(into destination: ImageDestination, start: ContinuousClock.Instant, allocated: Bool) throws -> DecodedImage {
        let d = destination.descriptor, budget = frame.budget
        try d.validate(limits: options.resourceLimits)
        guard d.width == width, d.height == height, d.sampleType == .unsignedInteger,
              d.meaningfulBits == frame.frame.precision, d.alpha == .absent, d.iccProfile == frame.metadata.iccProfile,
              d.colour == (roles.count == 1 ? .greyscale : .rgb),
              d.components.count == roles.count, roles.allSatisfy({ d.components.contains($0) }) else {
            throw CodecError(.incompatibleImageLayout, "JPEG destination interpretation differs from the decoded frame.")
        }
        let layouts = try channelLayouts(d, roles: roles)
        try budget.reservePixels(destination.storage.byteCount)
        options.progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: 1))
        try budget.checkpoint()
        let image = try destination.write(metadata: try imageMetadata(), beforeSeal: {
            try budget.checkpoint()
            options.progress?(try ProgressUpdate(phase: .completed, completedUnits: 1, totalUnits: 1))
            try budget.checkpoint()
        }) { bytes in try frame.decode(into: bytes, layouts: layouts, orientation: orientation) }
        let elapsed = start.duration(to: .now).components
        let fallback: String? = if case .preferred(.accelerated) = options.executionPolicy {
            "Accelerated backend unavailable; used scalar CPU."
        } else { nil }
        return .init(image: image, report: .init(backend: .scalarCPU, fallbackReason: fallback, fidelity: frame.frame.marker == 0xc3 && !frame.hasPointTransform ? .exactSamples : .lossy,
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
