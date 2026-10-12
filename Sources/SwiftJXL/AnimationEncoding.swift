// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXLCore

/// An immutable source owner with an explicit positive presentation duration.
public struct AnimationInputFrame: Sendable {
    public let image: Image
    public let durationTicks: UInt32
    public init(image: Image, durationTicks: UInt32 = 10) throws {
        guard durationTicks > 0 else { throw CodecError(.invalidArgument, "Animation frame duration must be positive.") }
        self.image = image; self.durationTicks = durationTicks
    }
}
/// Codec-specific exact animation clock. Zero loops means indefinite repetition.
/// The numerator range is 1...2^30 and denominator range is 1...1024, matching
/// the admitted JPEG XL clock fields. No floating-point time conversion occurs.
public struct AnimationEncodingOptions: Sendable, Equatable {
    public let ticksPerSecondNumerator: UInt32
    public let ticksPerSecondDenominator: UInt32
    public let loopCount: UInt32
    public init(ticksPerSecondNumerator: UInt32 = 100, ticksPerSecondDenominator: UInt32 = 1,
                loopCount: UInt32 = 0) throws {
        guard (1...(1 << 30)).contains(ticksPerSecondNumerator),
              (1...1024).contains(ticksPerSecondDenominator) else {
            throw CodecError(.invalidArgument, "Animation clock is outside the supported rational range.")
        }
        self.ticksPerSecondNumerator = ticksPerSecondNumerator
        self.ticksPerSecondDenominator = ticksPerSecondDenominator; self.loopCount = loopCount
    }
    private init() { ticksPerSecondNumerator = 100; ticksPerSecondDenominator = 1; loopCount = 0 }
    public static let `default` = Self()
}
/// Encoded sequence and exact timing. Temporary standalone compressed frame
/// sizes are reported separately from decoded pixel handoff copy events.
public struct EncodedAnimation: Sendable {
    public let encoded: EncodedImage
    public let timing: AnimationTiming
    public let frameCount: Int
    public let compressedFrameBytesMaterialised: Int
}

extension Encoder {
    /// Encodes independent full-canvas frames using this encoder's explicit mode.
    /// All frames must match geometry, precision, colour/alpha interpretation and
    /// metadata; their memory layouts may differ. A singleton remains an animation
    /// with its duration. No signedness conversion, compositing or pixel copy occurs.
    /// Pixel, decoded-byte and metadata ceilings apply to the aggregate sources;
    /// one deadline and one completed progress event cover the whole sequence.
    @concurrent public func encodeAnimation(_ frames: [AnimationInputFrame],
                                            animation: AnimationEncodingOptions = .default,
                                            options: EncodeOptions = .init()) async throws -> EncodedAnimation {
        let start = ContinuousClock.now
        do {
            try Task.checkCancellation()
            guard let first = frames.first else { throw CodecError(.invalidArgument, "Animation requires at least one frame.") }
            let limits = options.resourceLimits
            guard frames.count <= limits.maximumFrames else { throw CodecError(.resourceLimitExceeded, "Animation frame limit exceeded.") }
            if case .required(.accelerated) = options.executionPolicy { throw CodecError(.backendUnavailable, "No accelerated backend is implemented.") }
            var sourceBytes = 0, metadataBytes = try checkedAdd(20, checkedMultiply(frames.count, 12))
            var totalPixels = 0, totalTicks: UInt64 = 0
            for frame in frames {
                try Task.checkCancellation()
                let a = first.image.descriptor, b = frame.image.descriptor
                guard a.width == b.width, a.height == b.height, a.sampleType == b.sampleType,
                      a.meaningfulBits == b.meaningfulBits, a.colour == b.colour, a.alpha == b.alpha,
                      a.components == b.components, a.iccProfile == b.iccProfile,
                      first.image.metadata == frame.image.metadata else {
                    throw CodecError(.invalidArgument, "Animation source interpretation or geometry differs between frames.")
                }
                try b.validate(limits: limits)
                sourceBytes = try checkedAdd(sourceBytes, frame.image.storage.byteCount)
                metadataBytes = try checkedAdd(metadataBytes, frame.image.metadata.validate(limits: limits,
                    additionalBytes: b.iccProfile?.count ?? 0))
                totalPixels = try checkedAdd(totalPixels, checkedMultiply(b.width, b.height))
                let (ticks, overflow) = totalTicks.addingReportingOverflow(UInt64(frame.durationTicks))
                guard !overflow else { throw CodecError(.resourceLimitExceeded, "Animation timeline overflow.") }
                totalTicks = ticks
            }
            guard sourceBytes <= limits.maximumDecodedBytes, totalPixels <= limits.maximumPixels,
                  metadataBytes <= limits.maximumMetadataBytes else {
                throw CodecError(.resourceLimitExceeded, "Animation aggregate source limit exceeded.")
            }
            let deadline = start.advanced(by: .seconds(min(limits.deadlineSeconds, 31_536_000)))
            let retained = try checkedAdd(sourceBytes, metadataBytes)
            let budget = try ScalarOperationBudget(retainedBytes: retained,
                maximumWorkspaceBytes: limits.maximumWorkspaceBytes, maximumMemoryBytes: limits.maximumMemoryBytes,
                maximumDecodedBytes: limits.maximumDecodedBytes, maximumCompressedBytes: limits.maximumCompressedBytes,
                deadline: deadline, maximumWorkers: limits.maximumWorkers)
            // Conservative ceiling covers each still encoder's coefficient/output
            // bound, plus headers. Four ceilings admit growing final writer/Data,
            // current compressed frame and its temporary section slice. No pixels.
            let paddedWidth = try checkedMultiply(checkedAdd(first.image.descriptor.width, 7) / 8, 8)
            let paddedHeight = try checkedMultiply(checkedAdd(first.image.descriptor.height, 7) / 8, 8)
            let perPixel = max(12, try checkedMultiply(first.image.descriptor.components.count, 6))
            let frameBound = try checkedAdd(checkedMultiply(checkedMultiply(paddedWidth, paddedHeight), perPixel), 65536)
            let outputLimit = min(limits.maximumCompressedBytes,
                try checkedAdd(checkedMultiply(frameBound, frames.count), 65536))
            let assemblyWorkspace = try checkedAdd(checkedMultiply(outputLimit, 4), checkedMultiply(frames.count, 4096))
            try budget.reserveOutput(outputLimit)
            try budget.reserveWorkspace(assemblyWorkspace)
            let work = ScalarEncodingWork(budget: budget, writerByteLimit: outputLimit)
            var builder: AnimationCodestreamBuilder?, compressed = 0
            for (i, frame) in frames.enumerated() {
                try budget.checkpoint()
                options.progress?(try ProgressUpdate(phase: .processing, completedUnits: i, totalUnits: frames.count))
                try budget.checkpoint()
                let workspace = limits.maximumWorkspaceBytes - budget.reservedWorkspaceBytes
                let memory = limits.maximumMemoryBytes - (try checkedAdd(retained, checkedAdd(outputLimit, budget.reservedWorkspaceBytes)))
                guard workspace > 0, memory > 0 else { throw CodecError(.resourceLimitExceeded, "Animation assembly resource limit exceeded.") }
                let remaining = ContinuousClock.now.duration(to: deadline).components
                let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
                guard seconds > 0 else { throw CodecError(.resourceLimitExceeded, "Animation deadline exceeded.") }
                let childLimits = try ResourceLimits(maximumCompressedBytes: outputLimit,
                    maximumDecodedBytes: limits.maximumDecodedBytes, maximumWorkspaceBytes: workspace,
                    maximumPixels: limits.maximumPixels, maximumDimension: limits.maximumDimension, maximumFrames: 1,
                    maximumMetadataBytes: limits.maximumMetadataBytes, maximumICCBytes: limits.maximumICCBytes,
                    maximumNestingDepth: limits.maximumNestingDepth, maximumWorkers: limits.maximumWorkers,
                    deadlineSeconds: seconds, maximumMemoryBytes: memory)
                let encoded = try await encode(frame.image, options: .init(resourceLimits: childLimits,
                    executionPolicy: options.executionPolicy, copyPolicy: options.copyPolicy, metadataPolicy: options.metadataPolicy))
                try budget.checkpoint()
                let index = try AnimationFrameIndex.read(encoded.data, budget: budget, maximumFrames: 1,
                    maximumDimension: limits.maximumDimension, maximumPixels: limits.maximumPixels,
                    maximumNestingDepth: limits.maximumNestingDepth)
                if builder == nil {
                    builder = try AnimationCodestreamBuilder(first: index,
                        ticksNumerator: animation.ticksPerSecondNumerator,
                        ticksDenominator: animation.ticksPerSecondDenominator, loopCount: animation.loopCount, work: work)
                }
                try builder?.append(index, duration: frame.durationTicks, isLast: i == frames.count - 1)
                compressed = try checkedAdd(compressed, encoded.data.count)
            }
            guard var completed = builder else { throw CodecError(.internalFailure, "Missing animation assembler.") }
            let data = try completed.finish()
            options.progress?(try ProgressUpdate(phase: .completed, completedUnits: frames.count, totalUnits: frames.count))
            try budget.checkpoint()
            let elapsed = start.duration(to: .now).components
            let fallback: String? = if case .preferred(.accelerated) = options.executionPolicy { "Accelerated backend unavailable; used scalar CPU." } else { nil }
            let report = OperationReport(backend: .scalarCPU, fallbackReason: fallback,
                fidelity: configuration.mode == .lossless ? .exactSamples : .lossy,
                elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            return .init(encoded: .init(data: data, encoding: .init(format: "jpeg-xl", mode: configuration.mode), report: report),
                timing: .init(ticksPerSecondNumerator: animation.ticksPerSecondNumerator,
                    ticksPerSecondDenominator: animation.ticksPerSecondDenominator, loopCount: animation.loopCount, totalTicks: totalTicks),
                frameCount: frames.count, compressedFrameBytesMaterialised: compressed)
        } catch is CancellationError { throw CancellationError() }
        catch let error as CodecError { throw error }
        catch ScalarModularError.resourceLimit { throw CodecError(.resourceLimitExceeded, "Animation resource limit exceeded.") }
        catch ScalarModularError.unsupportedProfile { throw CodecError(.unsupportedFeature, "Unsupported animation frame profile.") }
        catch { throw CodecError(.internalFailure, "Animation assembly failed.") }
    }
}
