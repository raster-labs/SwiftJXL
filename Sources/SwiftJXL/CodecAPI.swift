// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXLCore

/// Explicit transform search scope; larger searches trade CPU and admitted
/// workspace for potential compressed-size savings, without changing fidelity mode.
public enum VarDCTStrategySearch: Sendable, Equatable {
    case fixedDCT8, singleCell, hierarchical
}

/// Explicit lossy VarDCT analysis settings. Distance is a positive finite codec
/// quality parameter, not an absolute sample-error or perceptual guarantee.
public struct VarDCTEncodingOptions: Sendable, Equatable {
    public let distance: Float
    public let gaborish: Bool
    public let adaptiveQuantisation: Bool
    public let dcSmoothing: Bool
    public let strategySearch: VarDCTStrategySearch
    public init(distance: Float = 1, gaborish: Bool = true,
                adaptiveQuantisation: Bool = true, dcSmoothing: Bool = true,
                strategySearch: VarDCTStrategySearch = .hierarchical) throws {
        guard distance.isFinite, distance > 0 else {
            throw CodecError(.invalidArgument, "VarDCT distance must be positive and finite.")
        }
        self.distance = distance; self.gaborish = gaborish
        self.adaptiveQuantisation = adaptiveQuantisation; self.dcSmoothing = dcSmoothing
        self.strategySearch = strategySearch
    }
    private init() { distance = 1; gaborish = true; adaptiveQuantisation = true; dcSmoothing = true; strategySearch = .hierarchical }
    public static let `default` = Self()
}
/// Modular uses fixed effort-3 lossless settings. VarDCT controls apply only
/// with EncoderConfiguration.mode == .lossy, never implicitly to lossless input.
public struct CodecOptions: Sendable, Equatable {
    public let varDCT: VarDCTEncodingOptions?
    public init(varDCT: VarDCTEncodingOptions? = nil) { self.varDCT = varDCT }
}
public struct EncoderConfiguration: Sendable, Equatable {
    public let mode: CompressionMode
    public let codecOptions: CodecOptions
    public init(mode: CompressionMode = .lossless, codecOptions: CodecOptions = .init()) throws {
        if case .nearLossless(let bound) = mode, bound <= 0 {
            throw CodecError(.invalidArgument, "Near-lossless error must be positive.")
        }
        guard mode == .lossless || mode == .lossy else {
            throw CodecError(.unsupportedFeature, "Near-lossless compression is not supported.")
        }
        guard mode == .lossy || codecOptions.varDCT == nil else {
            throw CodecError(.invalidArgument, "VarDCT controls require explicit lossy mode.")
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
/// sRGB/BT.709 transfer, rendering intent and alpha association are preserved
/// without conversion through the documented required metadata entries.
/// Explicit lossy mode selects bounded VarDCT sRGB 8–16-bit encoding with
/// relative intent and optional straight alpha, at most 4096 per axis and
/// 4,194,304 pixels. It reads the same owning layouts and reports lossy fidelity.
public struct Encoder: Sendable {
    public let configuration: EncoderConfiguration
    public static let capabilities = CodecCapabilities.pixelEncoding
    public var capabilities: CodecCapabilities { Self.capabilities }
    public init(configuration: EncoderConfiguration = .default) throws { self.configuration = configuration }

    @concurrent public func encode(_ image: Image, options: EncodeOptions = .init()) async throws -> EncodedImage {
        let start = ContinuousClock.now
        let cancellation = ScalarOperationCancellation()
        return try await withTaskCancellationHandler {
            return try translateScalarErrors(encoding: true) {
                try Task.checkCancellation()
                try validateOperation(options.executionPolicy)
                let limits = options.resourceLimits
                try image.descriptor.validate(limits: limits)
                let metadataBytes = try image.metadata.validate(limits: limits,
                    additionalBytes: image.descriptor.iccProfile?.count ?? 0)
                let layouts = try encoderSourceLayouts(image.descriptor)
                let intent = try renderingIntent(image.metadata)
                let transfer = try transferFunction(image.metadata)
                guard image.metadata.requiredKeys.subtracting([renderingIntentKey, transferFunctionKey]).isEmpty,
                      options.metadataPolicy == .discardAncillary || image.metadata.entries.keys.allSatisfy({ $0 == renderingIntentKey || $0 == transferFunctionKey }) else {
                    throw CodecError(.unsupportedFeature, "The pixel encoder cannot preserve this metadata.")
                }
                if configuration.mode == .lossy {
                    guard transfer == .srgb, intent == .relative,
                          image.descriptor.alpha != .premultiplied,
                          image.descriptor.width <= 4096, image.descriptor.height <= 4096,
                          try checkedMultiply(image.descriptor.width, image.descriptor.height) <= 4 * 1024 * 1024 else {
                        throw CodecError(.unsupportedFeature, "VarDCT requires bounded sRGB input with relative intent and optional straight alpha.")
                    }
                }
                guard image.storage.byteCount <= limits.maximumDecodedBytes else {
                    throw CodecError(.resourceLimitExceeded, "Source storage exceeds decoded limits.")
                }
                let budget = try operationBudget(limits, retained: checkedAdd(image.storage.byteCount, metadataBytes),
                    start: start, maximumWorkers: limits.maximumWorkers, cancellation: cancellation)
                try progress(options.progress, .processing, completed: 0)
                let data = try image.storage.withUnsafeBytes { bytes in
                    guard bytes.count == image.storage.byteCount, layouts.allSatisfy({ bytes.count >= $0.requiredBytes }) else {
                        throw CodecError(.storageUnavailable, "Source provider returned inconsistent capacity.")
                    }
                    if configuration.mode == .lossy {
                        let controls = configuration.codecOptions.varDCT ?? .default
                        return try VarDCTPixelEncoder.encode(bytes, layouts: layouts,
                            bitsPerSample: image.descriptor.meaningfulBits,
                            grayscale: image.descriptor.colour == .greyscale,
                            alphaAssociated: image.descriptor.alpha == .absent ? nil : false,
                            distance: controls.distance, gaborish: controls.gaborish,
                            adaptiveQuantisation: controls.adaptiveQuantisation,
                            dcSmoothing: controls.dcSmoothing,
                            smallStrategySearch: controls.strategySearch == .singleCell,
                            largeStrategySearch: controls.strategySearch == .hierarchical, budget: budget)
                    }
                    return try ModularStorageEncoder.encode(bytes, layouts: layouts,
                        bitsPerSample: image.descriptor.meaningfulBits, grayscale: image.descriptor.colour == .greyscale,
                        alphaAssociated: image.descriptor.alpha == .absent ? nil : image.descriptor.alpha == .premultiplied,
                        renderingIntent: intent, transferFunction: transfer, budget: budget)
                }
                try budget.checkpoint()
                try progress(options.progress, .completed, completed: 1)
                try budget.checkpoint()
                return EncodedImage(data: data, encoding: .init(format: "jpeg-xl", mode: configuration.mode),
                    report: scalarReport(options.executionPolicy, start: start,
                        fidelity: configuration.mode == .lossless ? .exactSamples : .lossy))
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// Single-frame integer Modular JPEG XL decoding, 1–16 meaningful bits,
/// greyscale or RGB with optional straight/premultiplied alpha. Supports bounded
/// groups, RCT, simple palettes and Squeeze. Caller storage may be planar or
/// interleaved, 8/16-bit, padded and either byte order. Embedded grey/RGB ICC
/// bytes are preserved without colour conversion. The still-image calls reject
/// animation; separate animation methods support independent full-canvas frames.
/// Ancillary boxes and display transformations are unsupported. VarDCT decoding additionally
/// accepts bounded single-frame, single-pass sRGB 8–16-bit grey/RGB with optional
/// straight alpha and default opsin/restoration parameters. It uses nearest
/// integer output and reports lossy fidelity. ICC VarDCT output is unsupported.
public struct Decoder: Sendable {
    public let configuration: DecoderConfiguration
    public static let capabilities = CodecCapabilities.pixelDecoding
    public var capabilities: CodecCapabilities { Self.capabilities }
    public init(configuration: DecoderConfiguration = .init()) throws {
        guard configuration.codecOptions.varDCT == nil else {
            throw CodecError(.invalidArgument, "VarDCT encoding controls are not decoder options.")
        }
        self.configuration = configuration
    }

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
            try destination.descriptor.validate(limits: options.resourceLimits)
            let (frame, budget) = try prepare(data, options: options, start: start,
                destinationBytes: destination.storage.byteCount,
                destinationMetadataBytes: destination.descriptor.iccProfile?.count ?? 0)
            return try finish(frame, into: destination, budget: budget, options: options, start: start)
        }
    }
}

private extension CodecCapabilities {
    static let pixelDecoding = Self(formats: ["jpeg-xl"], compressionModes: [.lossless, .lossy],
        sampleTypes: [.unsignedInteger], meaningfulPrecision: 1...16,
        layouts: ["Modular: 1–16-bit greyscale/RGB with optional alpha and ICC; planar/interleaved UInt8/UInt16",
                  "VarDCT: 8–16-bit sRGB greyscale/RGB with optional straight alpha; multiple DC/AC groups, single pass; explicit byte order, offsets and strides"],
        availableBackends: [.scalarCPU], canInspect: true, canEncode: false, canDecode: true)
    static let pixelEncoding = Self(formats: ["jpeg-xl"], compressionModes: [.lossless, .lossy],
        sampleTypes: [.unsignedInteger], meaningfulPrecision: 8...16,
        layouts: ["Modular: greyscale/RGB, optional alpha; fixed effort 3",
                  "VarDCT: sRGB greyscale/RGB, optional straight alpha; maximum 4096 per axis and 4,194,304 pixels",
                  "Planar/interleaved UInt8/UInt16; explicit byte order, offsets and strides"],
        availableBackends: [.scalarCPU], canInspect: false, canEncode: true, canDecode: false)
}

private func encoderSourceLayouts(_ d: ImageDescriptor) throws -> [ModularChannelLayout] {
    guard d.sampleType == .unsignedInteger, [8, 16].contains(d.storageBits),
          (8...16).contains(d.meaningfulBits), d.iccProfile == nil,
          d.width <= 16384, d.height <= 16384,
          d.colour == .greyscale || d.colour == .rgb else {
        throw CodecError(.unsupportedFeature, "Requires the supported unsigned integer pixel profile without ICC.")
    }
    let roles: [ComponentRole] = (d.colour == .greyscale ? [.grey] : [.red, .green, .blue]) +
        (d.alpha == .absent ? [] : [.alpha])
    guard d.components.count == roles.count, roles.allSatisfy({ d.components.contains($0) }) else {
        throw CodecError(.unsupportedFeature, "Unsupported source component roles.")
    }
    return try channelLayouts(d, roles: roles)
}
private func operationBudget(_ limits: ResourceLimits, retained: Int,
                             start: ContinuousClock.Instant, maximumWorkers: Int = 1,
                             cancellation: ScalarOperationCancellation? = nil) throws -> ScalarOperationBudget {
    // Values beyond a year need not extend a bounded scalar operation. Clamping
    // before Duration conversion also handles finite Double.greatestFiniteMagnitude.
    let deadline = start.advanced(by: .seconds(min(limits.deadlineSeconds, 31_536_000)))
    return try ScalarOperationBudget(retainedBytes: retained,
        maximumWorkspaceBytes: limits.maximumWorkspaceBytes, maximumMemoryBytes: limits.maximumMemoryBytes,
        maximumDecodedBytes: limits.maximumDecodedBytes, maximumCompressedBytes: limits.maximumCompressedBytes,
        deadline: deadline, maximumWorkers: maximumWorkers, cancellation: cancellation)
}
// The selected preparation retains the single parsed header and operation budget.
// Pixel buffers remain owned by ImageDestination until synchronous writing joins.
private enum PreparedPixelFrame: Sendable {
    case modular(ModularFrameDecoder.Prepared)
    case vardct(VarDCTFrameEnvelope)

    var width: Int { switch self { case .modular(let f): f.width; case .vardct(let f): f.width } }
    var height: Int { switch self { case .modular(let f): f.height; case .vardct(let f): f.height } }
    var bitsPerSample: Int {
        switch self { case .modular(let f): f.bitsPerSample; case .vardct(let f): Int(f.metadata.bitDepth.bitsPerSample) }
    }
    var grayscale: Bool {
        switch self { case .modular(let f): f.grayscale; case .vardct(let f): f.metadata.colorEncoding.colorSpace == .grayscale }
    }
    var alphaAssociated: Bool? {
        switch self { case .modular(let f): f.alphaAssociated; case .vardct(let f): f.metadata.extraChannels.first?.alphaAssociated }
    }
    var iccProfile: Data? {
        switch self { case .modular(let f): f.iccProfile; case .vardct(let f): f.iccProfile }
    }
    var renderingIntent: RenderingIntent {
        switch self { case .modular(let f): f.renderingIntent; case .vardct(let f): f.metadata.colorEncoding.renderingIntent }
    }
    var transferFunction: TransferFunction {
        switch self { case .modular(let f): f.transferFunction; case .vardct(let f): f.metadata.colorEncoding.transferFunction }
    }
    var fidelity: Fidelity { switch self { case .modular: .exactSamples; case .vardct: .lossy } }
    func decode(into bytes: UnsafeMutableRawBufferPointer, layouts: [ModularChannelLayout]) throws {
        switch self {
        case .modular(let f): try f.decode(into: bytes, layouts: layouts)
        case .vardct(let f): try VarDCTPixelDecoder.decode(f, into: bytes, layouts: layouts)
        }
    }
}

private func prepare(_ data: Data, options: DecodeOptions, start: ContinuousClock.Instant,
                     destinationBytes: Int = 0, destinationMetadataBytes: Int = 0) throws -> (PreparedPixelFrame, ScalarOperationBudget) {
    try Task.checkCancellation()
    try validateOperation(options.executionPolicy)
    let l = options.resourceLimits
    guard data.count <= l.maximumCompressedBytes else {
        throw CodecError(.resourceLimitExceeded, "Compressed input exceeds limits.")
    }
    let budget = try operationBudget(l, retained: checkedAdd(data.count, destinationMetadataBytes), start: start)
    try budget.reservePixels(destinationBytes)
    try progress(options.progress, .inspecting, completed: 0)
    let header = try PixelFrameHeader.read(data, budget: budget,
        maximumDimension: l.maximumDimension, maximumPixels: l.maximumPixels,
        maximumNestingDepth: l.maximumNestingDepth)
    let frame: PreparedPixelFrame
    if header.metadata.xybEncoded {
        let envelope = try VarDCTFrameEnvelope.read(header,
            maximumICCBytes: l.maximumICCBytes, maximumMetadataBytes: l.maximumMetadataBytes)
        // Keep public capability within the qualified integer output profile.
        // ICC and associated alpha cannot be silently interpreted as sRGB.
        guard (8...16).contains(Int(envelope.metadata.bitDepth.bitsPerSample)),
              envelope.iccProfile == nil,
              envelope.metadata.extraChannels.first?.alphaAssociated != true,
              envelope.frame.passes.numPasses == 1,
              !envelope.frame.loopFilter.hasCustomParameters else {
            throw ScalarModularError.unsupportedProfile
        }
        frame = .vardct(envelope)
    } else {
        frame = .modular(try ModularFrameDecoder.prepare(header,
            maximumICCBytes: l.maximumICCBytes, maximumMetadataBytes: l.maximumMetadataBytes))
    }
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
// JPEG XL standard transfer-function enum: 1=BT.709, 13=sRGB (implicit).
private let transferFunctionKey = "jpegXL.transferFunction"
private func transferFunction(_ metadata: ImageMetadata) throws -> TransferFunction {
    guard let value = metadata.entries[transferFunctionKey] else { return .srgb }
    guard value.count == 1 else { throw CodecError(.invalidArgument, "Invalid JPEG XL transfer metadata.") }
    switch value.first {
    case 1: return .bt709
    case 13: return .srgb
    default: throw CodecError(.unsupportedFeature, "Unsupported JPEG XL transfer function.")
    }
}
private func frameMetadata(_ frame: PreparedPixelFrame, limits: ResourceLimits) throws -> ImageMetadata {
    if let profile = frame.iccProfile {
        // The exact profile owns colour interpretation; do not invent a
        // separate sRGB/BT.709 transfer or rendering-intent override for it.
        _ = try ImageMetadata.empty.validate(limits: limits, additionalBytes: profile.count)
        return .empty
    }
    let byteCount = (frame.renderingIntent == .relative ? 0 : renderingIntentKey.utf8.count + 1)
        + (frame.transferFunction == .bt709 ? transferFunctionKey.utf8.count + 1 : 0)
    guard byteCount <= limits.maximumMetadataBytes else {
        throw CodecError(.resourceLimitExceeded, "Colour metadata exceeds limits.")
    }
    var entries: [String: Data] = [:]
    if frame.renderingIntent != .relative {
        entries[renderingIntentKey] = Data([UInt8(frame.renderingIntent.rawValue)])
    }
    if frame.transferFunction == .bt709 { entries[transferFunctionKey] = Data([1]) }
    let metadata = ImageMetadata(entries: entries, requiredKeys: Set(entries.keys))
    _ = try metadata.validate(limits: limits)
    return metadata
}
private func frameDescriptor(_ frame: PreparedPixelFrame, limits: ResourceLimits) throws -> ImageDescriptor {
    // Preserve the original greyscale default and use UInt16 for all allocating
    // decodes. Caller destinations may instead request UInt8 for 8-bit streams.
    let roles = frameRoles(frame)
    let stride = try checkedMultiply(roles.count, 2)
    let row = try checkedMultiply(frame.width, stride)
    let bytes = try checkedMultiply(row, frame.height)
    let plane = try PlaneDescriptor(width: frame.width, height: frame.height,
        components: Array(roles.indices), sampleStride: 2, pixelStride: stride, rowBytes: row, byteCount: bytes)
    return try ImageDescriptor(width: frame.width, height: frame.height, meaningfulBits: frame.bitsPerSample,
        components: roles, colour: frame.grayscale ? .greyscale : .rgb, alpha: frameAlpha(frame),
        planes: [plane], iccProfile: frame.iccProfile, limits: limits)
}
private func frameRoles(_ frame: PreparedPixelFrame) -> [ComponentRole] {
    (frame.grayscale ? [.grey] : [.red, .green, .blue]) + (frame.alphaAssociated == nil ? [] : [.alpha])
}
private func frameAlpha(_ frame: PreparedPixelFrame) -> AlphaInterpretation {
    guard let associated = frame.alphaAssociated else { return .absent }
    return associated ? .premultiplied : .straight
}
private func decodedLayouts(_ d: ImageDescriptor, frame: PreparedPixelFrame) throws -> [ModularChannelLayout] {
    let roles = frameRoles(frame)
    guard d.sampleType == .unsignedInteger, [8, 16].contains(d.storageBits) else {
        throw CodecError(.unsupportedFeature, "Requires unsigned 8/16-bit pixel storage.")
    }
    guard d.width == frame.width, d.height == frame.height, d.meaningfulBits == frame.bitsPerSample,
          d.colour == (frame.grayscale ? .greyscale : .rgb), d.alpha == frameAlpha(frame),
          d.iccProfile == frame.iccProfile,
          d.components.count == roles.count, roles.allSatisfy({ d.components.contains($0) }) else {
        throw CodecError(.incompatibleImageLayout, "Destination geometry, precision, colour, ICC or alpha differs from the frame.")
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
private func finish(_ frame: PreparedPixelFrame, into destination: ImageDestination,
                    budget: ScalarOperationBudget, options: DecodeOptions,
                    start: ContinuousClock.Instant) throws -> DecodedImage {
    let d = destination.descriptor
    try d.validate(limits: options.resourceLimits)
    let layouts = try decodedLayouts(d, frame: frame)
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
    return DecodedImage(image: image, report: scalarReport(options.executionPolicy, start: start, fidelity: frame.fidelity))
}
private func progress(_ callback: (@Sendable (ProgressUpdate) -> Void)?,
                      _ phase: ProgressUpdate.Phase, completed: Int) throws {
    try Task.checkCancellation()
    callback?(try ProgressUpdate(phase: phase, completedUnits: completed, totalUnits: 1))
    try Task.checkCancellation()
}
private func scalarReport(_ policy: ExecutionPolicy, start: ContinuousClock.Instant,
                          fidelity: Fidelity = .exactSamples) -> OperationReport {
    let elapsed = start.duration(to: .now).components
    let fallback: String?
    if case .preferred(.accelerated) = policy { fallback = "Accelerated backend unavailable; used scalar CPU." }
    else { fallback = nil }
    return OperationReport(backend: .scalarCPU, fallbackReason: fallback, fidelity: fidelity,
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
    catch VarDCTError.unsupportedStrategy {
        throw CodecError(.unsupportedFeature, "Unsupported VarDCT transform strategy.")
    }
    catch ScalarModularError.invalidInput(let message) {
        throw CodecError(encoding ? .invalidArgument : .malformedInput, message)
    }
    catch { throw CodecError(encoding ? .internalFailure : .malformedInput, "Invalid or unsupported scalar JPEG XL payload.") }
}
