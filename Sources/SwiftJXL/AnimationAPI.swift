// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXLCore

/// Exact animation clock and repetition count. Zero loops means indefinite
/// repetition; frame durations and starts are integer ticks, never rounded ms.
public struct AnimationTiming: Sendable, Equatable {
    public let ticksPerSecondNumerator: UInt32
    public let ticksPerSecondDenominator: UInt32
    public let loopCount: UInt32
    /// Duration of one cycle, excluding repetitions.
    public let totalTicks: UInt64
}
/// Header inspection of one independent full-canvas frame; pixels are not validated.
public struct AnimationFrameInfo: Sendable {
    public let index: Int
    public let startTick: UInt64
    public let durationTicks: UInt32
    public let image: ImageInfo
}
/// Sequence inspection. A still input has nil timing and one zero-duration frame.
public struct AnimationInfo: Sendable {
    public let timing: AnimationTiming?
    public let frames: [AnimationFrameInfo]
    /// Sum of standalone compressed frame sizes materialised during inspection.
    /// This is compressed workspace, not a decoded pixel handoff copy or RSS peak.
    public let compressedFrameBytesMaterialised: Int
}
/// One decoded frame retaining its immutable pixel owner and exact timing.
public struct DecodedAnimationFrame: Sendable {
    public let index: Int
    public let startTick: UInt64
    public let durationTicks: UInt32
    public let timing: AnimationTiming?
    public let decoded: DecodedImage
    public let compressedFrameBytesMaterialised: Int
}
/// Owning sequence result. No frame aliases a mutable decoder scratch buffer.
public struct DecodedAnimation: Sendable {
    public let timing: AnimationTiming?
    public let frames: [DecodedAnimationFrame]
    public let compressedFrameBytesMaterialised: Int
}

extension Decoder {
    /// Counts structurally validated independent frames, without decoding pixels.
    /// Rejects compositing, crop/reference dependencies, zero-duration animation
    /// frames, timecodes, ICC and custom transforms. This is not conformance validation.
    public func countFrames(_ data: Data, options: DecodeOptions = .init()) throws -> Int {
        do { return try AnimationContext(data, options: options).index.frames.count }
        catch { try animationFailure(error) }
    }
    /// Inspects all admitted frame headers and retains exact clock/loop metadata.
    /// Pixel corruption can still make subsequent decoding fail.
    public func inspectFrames(_ data: Data, options: DecodeOptions = .init()) throws -> AnimationInfo {
        do {
            let context = try AnimationContext(data, options: options)
            var frames: [AnimationFrameInfo] = [], metadataBytes = context.timelineMetadataBytes, compressed = 0
            for i in context.index.frames.indices {
                let bytes = try context.frameBytes(at: i, retainedPixels: 0, retainedMetadata: metadataBytes)
                let info = try inspect(bytes, options: context.childOptions(retainedPixels: 0, retainedMetadata: metadataBytes))
                metadataBytes = try checkedAdd(metadataBytes, info.metadata.validate(limits: options.resourceLimits,
                    additionalBytes: info.descriptor.iccProfile?.count ?? 0))
                try context.checkMetadata(metadataBytes)
                let entry = context.index.frames[i]
                frames.append(.init(index: i, startTick: entry.startTick, durationTicks: entry.duration, image: info))
                compressed = try checkedAdd(compressed, bytes.count)
            }
            try context.index.image.budget.checkpoint()
            return .init(timing: context.timing, frames: frames, compressedFrameBytesMaterialised: compressed)
        } catch { try animationFailure(error) }
    }
    /// Decodes only the selected independent frame after indexing the complete
    /// input. Other frame payloads are not pixel-validated. All index/count,
    /// workspace and deadline limits still apply to the complete input.
    @concurrent public func decodeFrame(_ data: Data, at index: Int,
                                        options: DecodeOptions = .init()) async throws -> DecodedAnimationFrame {
        guard index >= 0 else { throw CodecError(.invalidArgument, "Frame index must be nonnegative.") }
        do {
            let context = try AnimationContext(data, options: options)
            guard context.index.frames.indices.contains(index) else { throw CodecError(.invalidArgument, "Frame index out of range.") }
            try context.progress(.processing, completed: 0, total: 1)
            let frame = try await decodeAnimationFrame(context, at: index, retainedPixels: 0, retainedMetadata: context.timelineMetadataBytes)
            try context.progress(.completed, completed: 1, total: 1)
            return frame
        } catch { try animationFailure(error) }
    }
    /// Decodes all independent frames with aggregate retained pixel/metadata and
    /// memory ceilings. maximumPixels bounds width × height × frame count here;
    /// indexed decoding applies that ceiling to its one decoded frame. A single
    /// deadline covers scanning and every frame.
    /// Progress is serial per sequence; completed is emitted only once, after all
    /// frames succeed. The ordinary single-image decode still rejects animations.
    @concurrent public func decodeAll(_ data: Data, options: DecodeOptions = .init()) async throws -> DecodedAnimation {
        do {
            let context = try AnimationContext(data, options: options)
            let pixels = try checkedMultiply(checkedMultiply(context.index.image.width, context.index.image.height), context.index.frames.count)
            guard pixels <= options.resourceLimits.maximumPixels else { throw CodecError(.resourceLimitExceeded, "Sequence pixel limit exceeded.") }
            var frames: [DecodedAnimationFrame] = [], retainedPixels = 0, retainedMetadata = context.timelineMetadataBytes, compressed = 0
            for i in context.index.frames.indices {
                try context.progress(.processing, completed: i, total: context.index.frames.count)
                let frame = try await decodeAnimationFrame(context, at: i,
                    retainedPixels: retainedPixels, retainedMetadata: retainedMetadata)
                retainedPixels = try checkedAdd(retainedPixels, frame.decoded.image.storage.byteCount)
                retainedMetadata = try checkedAdd(retainedMetadata, frame.decoded.image.metadata.validate(limits: options.resourceLimits,
                    additionalBytes: frame.decoded.image.descriptor.iccProfile?.count ?? 0))
                try context.checkMetadata(retainedMetadata)
                compressed = try checkedAdd(compressed, frame.compressedFrameBytesMaterialised)
                frames.append(frame)
            }
            try context.progress(.completed, completed: frames.count, total: frames.count)
            return .init(timing: context.timing, frames: frames, compressedFrameBytesMaterialised: compressed)
        } catch { try animationFailure(error) }
    }
    private func decodeAnimationFrame(_ context: AnimationContext, at index: Int,
                                      retainedPixels: Int, retainedMetadata: Int) async throws -> DecodedAnimationFrame {
        let bytes = try context.frameBytes(at: index, retainedPixels: retainedPixels, retainedMetadata: retainedMetadata)
        let child = try context.childOptions(retainedPixels: retainedPixels, retainedMetadata: retainedMetadata)
        let decoded = try await decode(bytes, options: child)
        try context.index.image.budget.checkpoint()
        let entry = context.index.frames[index]
        return .init(index: index, startTick: entry.startTick, durationTicks: entry.duration,
            timing: context.timing, decoded: decoded, compressedFrameBytesMaterialised: bytes.count)
    }
}

private struct AnimationContext: Sendable {
    let index: AnimationFrameIndex
    let options: DecodeOptions
    let inputBytes: Int
    let timelineMetadataBytes: Int
    var timing: AnimationTiming? {
        index.animation.map { .init(ticksPerSecondNumerator: $0.tpsNumerator,
            ticksPerSecondDenominator: $0.tpsDenominator, loopCount: $0.numLoops, totalTicks: index.totalTicks) }
    }
    init(_ data: Data, options: DecodeOptions) throws {
        try Task.checkCancellation()
        if case .required(.accelerated) = options.executionPolicy {
            throw CodecError(.backendUnavailable, "No accelerated backend is implemented.")
        }
        self.options = options; inputBytes = data.count
        let limits = options.resourceLimits
        let budget = try ScalarOperationBudget(retainedBytes: data.count,
            maximumWorkspaceBytes: limits.maximumWorkspaceBytes, maximumMemoryBytes: limits.maximumMemoryBytes,
            maximumDecodedBytes: limits.maximumDecodedBytes, maximumCompressedBytes: limits.maximumCompressedBytes,
            deadline: .now.advanced(by: .seconds(min(limits.deadlineSeconds, 31_536_000))), maximumWorkers: limits.maximumWorkers)
        index = try AnimationFrameIndex.read(data, budget: budget, maximumFrames: limits.maximumFrames,
            maximumDimension: limits.maximumDimension, maximumPixels: limits.maximumPixels,
            maximumNestingDepth: limits.maximumNestingDepth)
        timelineMetadataBytes = index.animation == nil ? 0 : try checkedAdd(20, checkedMultiply(index.frames.count, 12))
        guard timelineMetadataBytes <= limits.maximumMetadataBytes else {
            throw CodecError(.resourceLimitExceeded, "Animation timeline metadata limit exceeded.")
        }
        // Admission for public result arrays, descriptors and per-frame metadata
        // container overhead, in addition to exact metadata value/key bytes below.
        try budget.reserveWorkspace(ScalarOperationBudget.product(index.frames.count, 4096))
    }
    func checkMetadata(_ bytes: Int) throws {
        guard bytes <= options.resourceLimits.maximumMetadataBytes else {
            throw CodecError(.resourceLimitExceeded, "Sequence metadata limit exceeded.")
        }
    }
    func frameBytes(at i: Int, retainedPixels: Int, retainedMetadata: Int) throws -> Data {
        let entry = try index.frame(at: i), limits = options.resourceLimits
        let frameLimit = min(limits.maximumCompressedBytes, try checkedAdd(entry.payloadRange.count, 65536))
        let workspace = try checkedAdd(index.image.budget.reservedWorkspaceBytes, checkedMultiply(frameLimit, 4))
        let total = try checkedAdd(inputBytes, checkedAdd(workspace, checkedAdd(retainedPixels, retainedMetadata)))
        guard workspace <= limits.maximumWorkspaceBytes, total <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Sequence compressed workspace limit exceeded.")
        }
        return try index.standaloneFrame(at: i)
    }
    func childOptions(retainedPixels: Int, retainedMetadata: Int) throws -> DecodeOptions {
        let budget = index.image.budget, limits = options.resourceLimits
        try budget.checkpoint()
        let parent = try checkedAdd(inputBytes, checkedAdd(budget.reservedWorkspaceBytes,
            checkedAdd(retainedPixels, retainedMetadata)))
        let memory = limits.maximumMemoryBytes - parent
        let workspace = limits.maximumWorkspaceBytes - budget.reservedWorkspaceBytes
        let decoded = limits.maximumDecodedBytes - retainedPixels
        let metadata = limits.maximumMetadataBytes - retainedMetadata
        let colour = index.image.metadata.colorEncoding
        let metadataFree = !colour.useICC && colour.transferFunction == .srgb && colour.renderingIntent == .relative
        guard memory > 0, workspace > 0, decoded > 0, metadata >= 0,
              metadata > 0 || metadataFree else {
            throw CodecError(.resourceLimitExceeded, "Sequence aggregate resource limit exceeded.")
        }
        let remaining = ContinuousClock.now.duration(to: budget.deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard seconds > 0 else { throw CodecError(.resourceLimitExceeded, "Sequence deadline exceeded.") }
        return DecodeOptions(resourceLimits: try ResourceLimits(maximumCompressedBytes: limits.maximumCompressedBytes,
            maximumDecodedBytes: decoded, maximumWorkspaceBytes: workspace, maximumPixels: limits.maximumPixels,
            maximumDimension: limits.maximumDimension, maximumFrames: 1,
            // ResourceLimits requires positive ceilings. A metadata-free child
            // can consume zero remaining bytes: its admitted header proves no
            // ICC/required interpretation entry will be allocated or returned.
            maximumMetadataBytes: max(1, metadata),
            maximumICCBytes: max(1, min(limits.maximumICCBytes, metadata)), maximumNestingDepth: limits.maximumNestingDepth,
            maximumWorkers: limits.maximumWorkers, deadlineSeconds: seconds, maximumMemoryBytes: memory),
            executionPolicy: options.executionPolicy, copyPolicy: options.copyPolicy,
            metadataPolicy: options.metadataPolicy)
    }
    func progress(_ phase: ProgressUpdate.Phase, completed: Int, total: Int) throws {
        try index.image.budget.checkpoint()
        options.progress?(try ProgressUpdate(phase: phase, completedUnits: completed, totalUnits: total))
        try index.image.budget.checkpoint()
    }
}

private func animationFailure(_ error: any Error) throws -> Never {
    switch error {
    case is CancellationError: throw CancellationError()
    case let error as CodecError: throw error
    case ScalarModularError.resourceLimit: throw CodecError(.resourceLimitExceeded, "Animation resource limit exceeded.")
    case ScalarModularError.unsupportedProfile: throw CodecError(.unsupportedFeature, "Unsupported animation profile.")
    default: throw CodecError(.malformedInput, "Invalid animation codestream.")
    }
}
