// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXLCore

/// The integer Modular profile uses fixed effort-3, lossless codec settings.
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

/// Lossless integer Modular JPEG XL encoding, 8–16 meaningful bits, greyscale
/// or RGB with optional alpha. Reads explicit UInt8/UInt16 planar/interleaved
/// layouts into admitted Int32 algorithm workspace. ICC is unsupported;
/// rendering intent and alpha association are preserved without conversion.
public struct Encoder: Sendable {
    public let configuration: EncoderConfiguration
    public static let capabilities = CodecCapabilities.modular(encoding: true)
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
            let layouts = try modularSourceLayouts(image.descriptor)
            let intent = try renderingIntent(image.metadata)
            guard image.metadata.requiredKeys.subtracting([renderingIntentKey]).isEmpty,
                  options.metadataPolicy == .discardAncillary || image.metadata.entries.keys.allSatisfy({ $0 == renderingIntentKey }) else {
                throw CodecError(.unsupportedFeature, "The Modular encoder cannot preserve this metadata.")
            }
            guard image.storage.byteCount <= limits.maximumDecodedBytes else {
                throw CodecError(.resourceLimitExceeded, "Source storage exceeds decoded limits.")
            }
            let budget = try operationBudget(limits, retained: checkedAdd(image.storage.byteCount, metadataBytes), start: start)
            try progress(options.progress, .processing, completed: 0)
            let data = try image.storage.withUnsafeBytes { bytes in
                guard bytes.count == image.storage.byteCount, layouts.allSatisfy({ bytes.count >= $0.requiredBytes }) else {
                    throw CodecError(.storageUnavailable, "Source provider returned inconsistent capacity.")
                }
                return try ModularStorageEncoder.encode(bytes, layouts: layouts,
                    bitsPerSample: image.descriptor.meaningfulBits, grayscale: image.descriptor.colour == .greyscale,
                    alphaAssociated: image.descriptor.alpha == .absent ? nil : image.descriptor.alpha == .premultiplied,
                    renderingIntent: intent, budget: budget)
            }
            try budget.checkpoint()
            try progress(options.progress, .completed, completed: 1)
            try budget.checkpoint()
            return EncodedImage(data: data, encoding: .init(format: "jpeg-xl", mode: .lossless),
                report: scalarReport(options.executionPolicy, start: start))
        }
    }
}

/// Single-frame integer Modular JPEG XL decoding, 8–16 meaningful bits,
/// greyscale or RGB with optional straight/premultiplied alpha. Supports bounded
/// groups, RCT, simple palettes and Squeeze. Caller storage may be planar or
/// interleaved, 8/16-bit, padded and either byte order. ICC, ancillary boxes,
/// animation and display transformations are not supported.
public struct Decoder: Sendable {
    public let configuration: DecoderConfiguration
    public static let capabilities = CodecCapabilities.modular(encoding: false)
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
    static func modular(encoding: Bool) -> Self {
        Self(formats: ["jpeg-xl"], compressionModes: [.lossless], sampleTypes: [.unsignedInteger],
             meaningfulPrecision: 8...16,
             layouts: ["greyscale or RGB, optional alpha; planar/interleaved UInt8/UInt16; explicit byte order, offsets and strides"],
             availableBackends: [.scalarCPU], canInspect: !encoding, canEncode: encoding, canDecode: !encoding)
    }
}

private func modularSourceLayouts(_ d: ImageDescriptor) throws -> [ModularChannelLayout] {
    guard d.sampleType == .unsignedInteger, [8, 16].contains(d.storageBits),
          (8...16).contains(d.meaningfulBits), d.iccProfile == nil,
          d.width <= 16384, d.height <= 16384,
          d.colour == .greyscale || d.colour == .rgb else {
        throw CodecError(.unsupportedFeature, "Requires the supported unsigned integer Modular profile without ICC.")
    }
    let roles: [ComponentRole] = (d.colour == .greyscale ? [.grey] : [.red, .green, .blue]) +
        (d.alpha == .absent ? [] : [.alpha])
    guard d.components.count == roles.count, roles.allSatisfy({ d.components.contains($0) }) else {
        throw CodecError(.unsupportedFeature, "Unsupported Modular source component roles.")
    }
    return try channelLayouts(d, roles: roles)
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
                     destinationBytes: Int = 0) throws -> (ModularFrameDecoder.Prepared, ScalarOperationBudget) {
    try Task.checkCancellation()
    try validateOperation(options.executionPolicy)
    let l = options.resourceLimits
    guard data.count <= l.maximumCompressedBytes else {
        throw CodecError(.resourceLimitExceeded, "Compressed input exceeds limits.")
    }
    let budget = try operationBudget(l, retained: data.count, start: start)
    try budget.reservePixels(destinationBytes)
    try progress(options.progress, .inspecting, completed: 0)
    let frame = try ModularFrameDecoder.prepare(data, budget: budget,
        maximumDimension: l.maximumDimension, maximumPixels: l.maximumPixels,
        maximumNestingDepth: l.maximumNestingDepth)
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
private func frameMetadata(_ frame: ModularFrameDecoder.Prepared, limits: ResourceLimits) throws -> ImageMetadata {
    guard frame.renderingIntent != .relative else { return .empty }
    guard renderingIntentKey.utf8.count + 1 <= limits.maximumMetadataBytes else {
        throw CodecError(.resourceLimitExceeded, "Rendering-intent metadata exceeds limits.")
    }
    return ImageMetadata(entries: [renderingIntentKey: Data([UInt8(frame.renderingIntent.rawValue)])],
                         requiredKeys: [renderingIntentKey])
}
private func frameDescriptor(_ frame: ModularFrameDecoder.Prepared, limits: ResourceLimits) throws -> ImageDescriptor {
    // Preserve the original greyscale default and use UInt16 for all allocating
    // decodes. Caller destinations may instead request UInt8 for 8-bit streams.
    let roles = frameRoles(frame)
    let stride = try checkedMultiply(roles.count, 2)
    let row = try checkedMultiply(frame.width, stride)
    let bytes = try checkedMultiply(row, frame.height)
    let plane = try PlaneDescriptor(width: frame.width, height: frame.height,
        components: Array(roles.indices), sampleStride: 2, pixelStride: stride, rowBytes: row, byteCount: bytes)
    return try ImageDescriptor(width: frame.width, height: frame.height, meaningfulBits: frame.bitsPerSample,
        components: roles, colour: frame.grayscale ? .greyscale : .rgb, alpha: frameAlpha(frame), planes: [plane], limits: limits)
}
private func frameRoles(_ frame: ModularFrameDecoder.Prepared) -> [ComponentRole] {
    (frame.grayscale ? [.grey] : [.red, .green, .blue]) + (frame.alphaAssociated == nil ? [] : [.alpha])
}
private func frameAlpha(_ frame: ModularFrameDecoder.Prepared) -> AlphaInterpretation {
    guard let associated = frame.alphaAssociated else { return .absent }
    return associated ? .premultiplied : .straight
}
private func modularLayouts(_ d: ImageDescriptor, frame: ModularFrameDecoder.Prepared) throws -> [ModularChannelLayout] {
    let roles = frameRoles(frame)
    guard d.sampleType == .unsignedInteger, [8, 16].contains(d.storageBits),
          d.iccProfile == nil else {
        throw CodecError(.unsupportedFeature, "Requires unsigned 8/16-bit Modular storage without ICC.")
    }
    guard d.width == frame.width, d.height == frame.height, d.meaningfulBits == frame.bitsPerSample,
          d.colour == (frame.grayscale ? .greyscale : .rgb), d.alpha == frameAlpha(frame),
          d.components.count == roles.count, roles.allSatisfy({ d.components.contains($0) }) else {
        throw CodecError(.incompatibleImageLayout, "Destination geometry, precision, colour or alpha differs from the frame.")
    }
    return try channelLayouts(d, roles: roles)
}
private func channelLayouts(_ d: ImageDescriptor, roles: [ComponentRole]) throws -> [ModularChannelLayout] {
    // The validated descriptor maps each component exactly once and prevents
    // plane overlap. Resolve roles explicitly, including BGR and reversed planes.
    return try roles.map { role in
        guard let component = d.components.firstIndex(of: role),
              let plane = d.planes.first(where: { $0.components.contains(component) }),
              let position = plane.components.firstIndex(of: component) else {
            throw CodecError(.incompatibleImageLayout, "Destination component mapping is incomplete.")
        }
        return try ModularChannelLayout(width: d.width, height: d.height,
            offset: checkedAdd(plane.offset, checkedMultiply(position, plane.sampleStride)),
            rowBytes: plane.rowBytes, pixelStride: plane.pixelStride,
            storageBits: d.storageBits, littleEndian: d.byteOrder == .littleEndian)
    }
}
private func finish(_ frame: ModularFrameDecoder.Prepared, into destination: ImageDestination,
                    budget: ScalarOperationBudget, options: DecodeOptions,
                    start: ContinuousClock.Instant) throws -> DecodedImage {
    let d = destination.descriptor
    try d.validate(limits: options.resourceLimits)
    let layouts = try modularLayouts(d, frame: frame)
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
        try frame.decode(into: bytes, layouts: layouts)
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
