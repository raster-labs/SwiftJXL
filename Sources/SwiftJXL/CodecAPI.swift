// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXLCore

/// The initial scalar profile uses fixed, lossless codec settings.
public struct CodecOptions: Sendable, Equatable { public init() {} }
public struct EncoderConfiguration: Sendable, Equatable {
    public let mode: CompressionMode
    public let codecOptions: CodecOptions
    public init(mode: CompressionMode = .lossless, codecOptions: CodecOptions = .init()) throws {
        if case .nearLossless(let bound) = mode, bound <= 0 {
            throw CodecError(.invalidArgument, "Near-lossless error must be positive.")
        }
        guard mode == .lossless else {
            throw CodecError(.unsupportedFeature, "Only lossless compression is currently supported.")
        }
        self.mode = mode; self.codecOptions = codecOptions
    }
    private init() { mode = .lossless; codecOptions = .init() }
    public static let `default` = Self()
}
public struct DecoderConfiguration: Sendable, Equatable {
    public let codecOptions: CodecOptions
    public init(codecOptions: CodecOptions = .init()) { self.codecOptions = codecOptions }
}

public struct CodecCapabilities: Sendable, Equatable {
    public let formats: [String]
    public let compressionModes: [CompressionMode]
    public let sampleTypes: [SampleType]
    public let meaningfulPrecision: ClosedRange<Int>?
    public let layouts: [String]
    public let availableBackends: [Backend]
    public let canInspect: Bool
    public let canEncode: Bool
    public let canDecode: Bool
    public static let contractOnly = Self(formats: [], compressionModes: [], sampleTypes: [],
        meaningfulPrecision: nil, layouts: [], availableBackends: [],
        canInspect: false, canEncode: false, canDecode: false)
}

public struct CopyEvent: Sendable, Equatable {
    public let reason: String
    public let bytesMoved: Int
    public let sourceLayout: String
    public let destinationLayout: String
    public init(reason: String, bytesMoved: Int, sourceLayout: String, destinationLayout: String) throws {
        guard bytesMoved >= 0 else { throw CodecError(.invalidArgument, "Copy byte count must not be negative.") }
        self.reason = reason; self.bytesMoved = bytesMoved
        self.sourceLayout = sourceLayout; self.destinationLayout = destinationLayout
    }
}
public enum Fidelity: Sendable, Equatable { case exactSamples, boundedError(Int), lossy, originalBitstream }
public struct OperationReport: Sendable, Equatable {
    public let backend: Backend
    public let fallbackReason: String?
    public let fidelity: Fidelity
    public let copyEvents: [CopyEvent]
    public let pixelAllocationCount: Int?
    public let peakPixelBytes: Int?
    public let peakWorkspaceBytes: Int?
    public let elapsedSeconds: Double?
    public init(backend: Backend, fallbackReason: String? = nil, fidelity: Fidelity,
                copyEvents: [CopyEvent] = [], pixelAllocationCount: Int? = nil,
                peakPixelBytes: Int? = nil, peakWorkspaceBytes: Int? = nil, elapsedSeconds: Double? = nil) {
        self.backend = backend; self.fallbackReason = fallbackReason; self.fidelity = fidelity
        self.copyEvents = copyEvents; self.pixelAllocationCount = pixelAllocationCount
        self.peakPixelBytes = peakPixelBytes; self.peakWorkspaceBytes = peakWorkspaceBytes
        self.elapsedSeconds = elapsedSeconds
    }
}
public struct ImageInfo: Sendable {
    public let format: String
    public let descriptor: ImageDescriptor
    public let frameCount: Int
    public let metadata: ImageMetadata
}
public struct EncodingDescription: Sendable, Equatable {
    public let format: String
    public let mode: CompressionMode
}
public struct EncodedImage: Sendable {
    public let data: Data
    public let encoding: EncodingDescription
    public let report: OperationReport
}
public struct DecodedImage: Sendable {
    public let image: Image
    public let report: OperationReport
}

/// Lossless unsigned greyscale JPEG XL encoding, 9–16 meaningful bits in
/// 16-bit shared storage, up to 512 × 512 pixels. ICC and required metadata
/// are unsupported. Algorithm working memory is admitted before source access.
public struct Encoder: Sendable {
    public let configuration: EncoderConfiguration
    public static let capabilities = CodecCapabilities.scalar(encoding: true)
    public var capabilities: CodecCapabilities { Self.capabilities }
    public init(configuration: EncoderConfiguration = .default) throws { self.configuration = configuration }

    @concurrent public func encode(_ image: Image, options: EncodeOptions = .init()) async throws -> EncodedImage {
        let start = ContinuousClock.now
        return try translateScalarErrors(encoding: true) {
            try Task.checkCancellation()
            try validateOperation(options.executionPolicy)
            let limits = options.resourceLimits
            try image.descriptor.validate(limits: limits)
            let metadataBytes = try image.metadata.validate(limits: limits,
                additionalBytes: image.descriptor.iccProfile?.count ?? 0)
            let layout = try scalarLayout(image.descriptor, encoding: true)
            let intent = try renderingIntent(image.metadata)
            guard image.metadata.requiredKeys.subtracting([renderingIntentKey]).isEmpty,
                  options.metadataPolicy == .discardAncillary || image.metadata.entries.keys.allSatisfy({ $0 == renderingIntentKey }) else {
                throw CodecError(.unsupportedFeature, "The scalar encoder cannot preserve this metadata.")
            }
            guard image.storage.byteCount <= limits.maximumDecodedBytes else {
                throw CodecError(.resourceLimitExceeded, "Source storage exceeds decoded limits.")
            }
            let budget = try operationBudget(limits, retained: checkedAdd(image.storage.byteCount, metadataBytes), start: start)
            try progress(options.progress, .processing, completed: 0)
            let data = try image.storage.withUnsafeBytes { bytes in
                guard bytes.count == image.storage.byteCount, bytes.count >= layout.requiredBytes else {
                    throw CodecError(.storageUnavailable, "Source provider returned inconsistent capacity.")
                }
                return try ScalarModularEncoder.encode(bytes, layout: layout,
                    bitsPerSample: image.descriptor.meaningfulBits, renderingIntent: intent, budget: budget)
            }
            try budget.checkpoint()
            try progress(options.progress, .completed, completed: 1)
            try budget.checkpoint()
            return EncodedImage(data: data, encoding: .init(format: "jpeg-xl", mode: .lossless),
                report: scalarReport(options.executionPolicy, start: start))
        }
    }
}

/// Single-frame, single-group unsigned greyscale JPEG XL decoding into 16-bit
/// storage. Initial profile: 8–16 meaningful bits, at most 1024 × 1024 pixels,
/// no transforms, ICC, ancillary boxes, animation or display transformations.
public struct Decoder: Sendable {
    public let configuration: DecoderConfiguration
    public static let capabilities = CodecCapabilities.scalar(encoding: false)
    public var capabilities: CodecCapabilities { Self.capabilities }
    public init(configuration: DecoderConfiguration = .init()) throws { self.configuration = configuration }

    /// Parses and validates the supported headers; does not validate pixel payloads.
    public func inspect(_ data: Data, options: DecodeOptions = .init()) throws -> ImageInfo {
        try translateScalarErrors {
            let (frame, budget) = try prepare(data, options: options, start: .now)
            let descriptor = try frameDescriptor(frame, limits: options.resourceLimits)
            try budget.checkpoint()
            return ImageInfo(format: "jpeg-xl", descriptor: descriptor, frameCount: 1, metadata: try frameMetadata(frame, limits: options.resourceLimits))
        }
    }
    @concurrent public func decode(_ data: Data, options: DecodeOptions = .init()) async throws -> DecodedImage {
        let start = ContinuousClock.now
        return try translateScalarErrors {
            let (frame, budget) = try prepare(data, options: options, start: start)
            let descriptor = try frameDescriptor(frame, limits: options.resourceLimits)
            try budget.reservePixels(descriptor.requiredByteCount)
            let destination = try ImageDestination.allocate(descriptor: descriptor, limits: options.resourceLimits)
            return try finish(frame, into: destination, budget: budget, options: options, start: start)
        }
    }
    @concurrent public func decode(_ data: Data, into destination: ImageDestination,
                                  options: DecodeOptions = .init()) async throws -> DecodedImage {
        let start = ContinuousClock.now
        return try translateScalarErrors {
            // Account the caller's entire retained allocation before parsing.
            let (frame, budget) = try prepare(data, options: options, start: start,
                                              destinationBytes: destination.storage.byteCount)
            return try finish(frame, into: destination, budget: budget, options: options, start: start)
        }
    }
}

private extension CodecCapabilities {
    static func scalar(encoding: Bool) -> Self {
        Self(formats: ["jpeg-xl"], compressionModes: [.lossless], sampleTypes: [.unsignedInteger],
             meaningfulPrecision: encoding ? 9...16 : 8...16,
             layouts: ["single-plane greyscale UInt16; explicit byte order, row padding and pixel stride"],
             availableBackends: [.scalarCPU], canInspect: !encoding, canEncode: encoding, canDecode: !encoding)
    }
}

private func scalarLayout(_ d: ImageDescriptor, encoding: Bool) throws -> ScalarPlaneLayout {
    guard d.sampleType == .unsignedInteger, d.storageBits == 16,
          (encoding ? 9...16 : 8...16).contains(d.meaningfulBits),
          d.components == [.grey], d.colour == .greyscale, d.alpha == .absent,
          d.planes.count == 1, d.iccProfile == nil,
          d.width <= (encoding ? 512 : 1024), d.height <= (encoding ? 512 : 1024) else {
        throw CodecError(.unsupportedFeature, "Requires the supported unsigned UInt16 greyscale profile without ICC.")
    }
    let p = d.planes[0]
    return try ScalarPlaneLayout(width: d.width, height: d.height, offset: p.offset,
        rowBytes: p.rowBytes, pixelStride: p.pixelStride, littleEndian: d.byteOrder == .littleEndian)
}
private func operationBudget(_ limits: ResourceLimits, retained: Int,
                             start: ContinuousClock.Instant) throws -> ScalarOperationBudget {
    // Values beyond a year need not extend a bounded scalar operation. Clamping
    // before Duration conversion also handles finite Double.greatestFiniteMagnitude.
    let deadline = start.advanced(by: .seconds(min(limits.deadlineSeconds, 31_536_000)))
    return try ScalarOperationBudget(retainedBytes: retained,
        maximumWorkspaceBytes: limits.maximumWorkspaceBytes, maximumMemoryBytes: limits.maximumMemoryBytes,
        maximumDecodedBytes: limits.maximumDecodedBytes, maximumCompressedBytes: limits.maximumCompressedBytes,
        deadline: deadline)
}
private func prepare(_ data: Data, options: DecodeOptions, start: ContinuousClock.Instant,
                     destinationBytes: Int = 0) throws -> (ScalarModularFrame, ScalarOperationBudget) {
    try Task.checkCancellation()
    try validateOperation(options.executionPolicy)
    let l = options.resourceLimits
    guard data.count <= l.maximumCompressedBytes else {
        throw CodecError(.resourceLimitExceeded, "Compressed input exceeds limits.")
    }
    let budget = try operationBudget(l, retained: data.count, start: start)
    try budget.reservePixels(destinationBytes)
    try progress(options.progress, .inspecting, completed: 0)
    let policy = try ScalarDecodePolicy(maximumCompressedBytes: l.maximumCompressedBytes,
        maximumPixels: l.maximumPixels, maximumDimension: l.maximumDimension,
        maximumNestingDepth: l.maximumNestingDepth, maximumEntropyTableBytes: l.maximumWorkspaceBytes,
        budget: budget, deadline: budget.deadline)
    let frame = try ScalarModularDecoder.prepare(data, policy: policy)
    _ = try frameMetadata(frame, limits: l)
    return (frame, budget)
}
// A required, one-byte rendering-intent entry preserves the distinction between
// relative (the implicit default) and the other standard JPEG XL intents.
private let renderingIntentKey = "jpegXL.renderingIntent"
private func renderingIntent(_ metadata: ImageMetadata) throws -> RenderingIntent {
    guard let value = metadata.entries[renderingIntentKey] else { return .relative }
    guard value.count == 1, let byte = value.first, let intent = RenderingIntent(rawValue: UInt32(byte)) else {
        throw CodecError(.invalidArgument, "Invalid JPEG XL rendering-intent metadata.")
    }
    return intent
}
private func frameMetadata(_ frame: ScalarModularFrame, limits: ResourceLimits) throws -> ImageMetadata {
    guard frame.renderingIntent != .relative else { return .empty }
    guard renderingIntentKey.utf8.count + 1 <= limits.maximumMetadataBytes else {
        throw CodecError(.resourceLimitExceeded, "Rendering-intent metadata exceeds limits.")
    }
    return ImageMetadata(entries: [renderingIntentKey: Data([UInt8(frame.renderingIntent.rawValue)])],
                         requiredKeys: [renderingIntentKey])
}
private func frameDescriptor(_ frame: ScalarModularFrame, limits: ResourceLimits) throws -> ImageDescriptor {
    try .greyscale16(width: frame.width, height: frame.height, meaningfulBits: frame.bitsPerSample, limits: limits)
}
private func finish(_ frame: ScalarModularFrame, into destination: ImageDestination,
                    budget: ScalarOperationBudget, options: DecodeOptions,
                    start: ContinuousClock.Instant) throws -> DecodedImage {
    let d = destination.descriptor
    try d.validate(limits: options.resourceLimits)
    let layout = try scalarLayout(d, encoding: false)
    guard d.width == frame.width, d.height == frame.height, d.meaningfulBits == frame.bitsPerSample else {
        throw CodecError(.incompatibleImageLayout, "Destination dimensions or meaningful precision differ from the frame.")
    }
    try budget.reservePixels(destination.storage.byteCount)
    try progress(options.progress, .processing, completed: 0)
    try budget.checkpoint()
    let metadata = try frameMetadata(frame, limits: options.resourceLimits)
    let image = try destination.write(metadata: metadata, beforeSeal: {
        try budget.checkpoint()
        try progress(options.progress, .completed, completed: 1)
        try budget.checkpoint()
    }) { bytes in
        try frame.decode(into: bytes, layout: layout)
        try budget.checkpoint()
    }
    try budget.checkpoint()
    return DecodedImage(image: image, report: scalarReport(options.executionPolicy, start: start))
}
private func progress(_ callback: (@Sendable (ProgressUpdate) -> Void)?,
                      _ phase: ProgressUpdate.Phase, completed: Int) throws {
    try Task.checkCancellation()
    callback?(try ProgressUpdate(phase: phase, completedUnits: completed, totalUnits: 1))
    try Task.checkCancellation()
}
private func scalarReport(_ policy: ExecutionPolicy, start: ContinuousClock.Instant) -> OperationReport {
    let elapsed = start.duration(to: .now).components
    let fallback: String?
    if case .preferred(.accelerated) = policy { fallback = "Accelerated backend unavailable; used scalar CPU." }
    else { fallback = nil }
    return OperationReport(backend: .scalarCPU, fallbackReason: fallback, fidelity: .exactSamples,
        elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
}
private func validateOperation(_ policy: ExecutionPolicy) throws {
    if case .required(.accelerated) = policy {
        throw CodecError(.backendUnavailable, "No accelerated backend is implemented.")
    }
}
private func translateScalarErrors<T>(encoding: Bool = false, _ body: () throws -> T) throws -> T {
    do { return try body() }
    catch is CancellationError { throw CancellationError() }
    catch let error as CodecError { throw error }
    catch ScalarModularError.resourceLimit {
        throw CodecError(.resourceLimitExceeded, "Scalar operation exceeded its memory or work limit.")
    }
    catch ScalarModularError.unsupportedProfile {
        throw CodecError(.unsupportedFeature, "JPEG XL input is outside the supported scalar profile.")
    }
    catch ScalarModularError.invalidInput(let message) {
        throw CodecError(encoding ? .invalidArgument : .malformedInput, message)
    }
    catch { throw CodecError(encoding ? .internalFailure : .malformedInput, "Invalid or unsupported scalar JPEG XL payload.") }
}
