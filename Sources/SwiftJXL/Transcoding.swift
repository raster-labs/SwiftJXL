// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXLCore

/// Native compressed endpoints for original-JPEG byte preservation.
public enum TranscodeTarget: String, Sendable, CaseIterable {
    case jpegXL, jpeg
}

/// These fidelity guarantees are distinct; JPEG reconstruction requires the latter.
public enum TranscodePreservation: Sendable {
    case exactSamples, originalBitstream
}

/// A qualified native format-pair path, once codec migration supplies one.
public enum TranscodeProcessingPath: Sendable {
    case coefficients, reconstruction, sharedSamples
}

/// Empty capability collections mean no direction has been implemented or qualified.
public struct TranscodeCapability: Sendable {
    public let source: TranscodeTarget
    public let target: TranscodeTarget
    public let preservation: TranscodePreservation
    public let profileLimits: [String]
    public let processingPaths: [TranscodeProcessingPath]
}

/// Immutable lossless policy. Configuration does not imply an implemented codec.
public struct TranscoderConfiguration: Sendable {
    public let mode: CompressionMode

    public init(mode: CompressionMode = .lossless) throws {
        guard mode == .lossless else {
            throw CodecError(.unsupportedFeature, "Native transcoding requires the lossless preservation policy.")
        }
        self.mode = mode
    }

    private init(lossless: Bool) { mode = .lossless }
    public static let `default` = Self(lossless: true)
}

/// The common operation policies have exactly the encode option vocabulary.
public typealias TranscodeOptions = EncodeOptions

/// In-memory native JPEG coefficient recompression and autonomous reconstruction.
/// No pixel conversion, external codec, original-source lookup or disk staging.
public struct Transcoder: Sendable {
    public let configuration: TranscoderConfiguration
    public static let capabilities: [TranscodeCapability] = [
        .init(source: .jpeg, target: .jpegXL, preservation: .originalBitstream,
              profileLimits: profileLimits, processingPaths: [.coefficients]),
        .init(source: .jpegXL, target: .jpeg, preservation: .originalBitstream,
              profileLimits: profileLimits, processingPaths: [.reconstruction])
    ]
    public var capabilities: [TranscodeCapability] { Self.capabilities }
    private static let profileLimits = [
        "8-bit baseline, extended-sequential and progressive Huffman JPEG; one or three components",
        "Greyscale, 4:4:4, 4:2:2, 4:2:0 and 4:4:0; dimensions at most 2048 per side",
        "64 MiB compressed/coefficient limits; bounded metadata and caller resource ceilings",
        "Reverse requires one valid jbrd box and the supported single-pass DCT8 coefficient frame",
        "RGB/greyscale ICC profiles up to the caller limit (maximum 4 MiB); multiple DC groups/passes, arithmetic JPEG, CMYK and unsupported markers reject explicitly"
    ]

    public init(configuration: TranscoderConfiguration = .default) throws {
        self.configuration = configuration
    }

    /// Runs on the generic executor; retains compressed input until return.
    @concurrent
    public func transcode(_ data: Data, to target: TranscodeTarget,
                          options: TranscodeOptions = .init()) async throws -> EncodedImage {
        let start = ContinuousClock.now
        do {
            try Task.checkCancellation()
            let limits = options.resourceLimits
            guard data.count <= limits.maximumCompressedBytes, data.count <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Compressed input exceeds the admission budget.")
            }
            if case .required(.accelerated) = options.executionPolicy {
                throw CodecError(.backendUnavailable, "No accelerated backend is implemented.")
            }
            guard options.metadataPolicy == .preserve else {
                throw CodecError(.invalidArgument, "Original JPEG byte restoration cannot discard ancillary metadata.")
            }
            let policy = try JPEGNativePolicy(compressed: limits.maximumCompressedBytes,
                coefficients: limits.maximumDecodedBytes, workspace: limits.maximumWorkspaceBytes,
                memory: limits.maximumMemoryBytes, metadata: limits.maximumMetadataBytes,
                dimension: limits.maximumDimension, pixels: limits.maximumPixels, nesting: limits.maximumNestingDepth, icc: limits.maximumICCBytes,
                deadline: start.advanced(by: .seconds(min(limits.deadlineSeconds, 31_536_000))))
            options.progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: 1))
            try policy.checkpoint()
            let result: JPEGNativeResult
            switch target {
            case .jpegXL: result = try JPEGNativeTranscode.encode(data, policy: policy)
            case .jpeg: result = try JPEGNativeTranscode.reconstruct(data, policy: policy)
            }
            try policy.checkpoint()
            options.progress?(try ProgressUpdate(phase: .completed, completedUnits: 1, totalUnits: 1))
            try policy.checkpoint()
            let elapsed = start.duration(to: .now).components
            let fallback: String?
            if case .preferred(.accelerated) = options.executionPolicy { fallback = "Accelerated backend unavailable; used scalar CPU." }
            else { fallback = nil }
            let copy = try CopyEvent(reason: "Compressed container payload assembly/extraction; entropy workspace copies are not measured",
                bytesMoved: result.containerCopyBytes, sourceLayout: "compressed payloads", destinationLayout: "compressed payloads")
            return EncodedImage(data: result.data, encoding: .init(format: target == .jpegXL ? "jpeg-xl" : "jpeg", mode: .lossless),
                report: .init(backend: .scalarCPU, fallbackReason: fallback, fidelity: .originalBitstream,
                    copyEvents: [copy], elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18))
        } catch is CancellationError { throw CancellationError() }
        catch let error as CodecError { throw error }
        catch JPEGEntropyError.resourceLimit { throw Self.limitError }
        catch JPEGFrameError.resourceLimit { throw Self.limitError }
        catch JPEGParseError.resourceLimit { throw Self.limitError }
        catch JBRDError.resourceLimit { throw Self.limitError }
        catch BrotliError.resourceLimit { throw Self.limitError }
        catch ScalarModularError.resourceLimit { throw Self.limitError }
        catch JPEGEntropyError.unsupported { throw Self.profileError }
        catch JPEGFrameError.unsupported { throw Self.profileError }
        catch ScalarModularError.unsupportedProfile { throw Self.profileError }
        catch { throw CodecError(.malformedInput, "Invalid JPEG or JPEG XL reconstruction data.") }
    }
    private static var limitError: CodecError { .init(.resourceLimitExceeded, "Native transcoding exceeded a resource or deadline limit.") }
    private static var profileError: CodecError { .init(.unsupportedFeature, "Input is outside the supported native JPEG reconstruction profile.") }
}
