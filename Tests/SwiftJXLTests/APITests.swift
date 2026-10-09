// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL

func expectAsyncCodecError(_ category: CodecError.Category,
                          _ operation: () async throws -> Void,
                          sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        try await operation()
        Issue.record("Expected a defined codec error", sourceLocation: sourceLocation)
    } catch let error as CodecError {
        #expect(error.category == category, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Expected CodecError; received \(error)", sourceLocation: sourceLocation)
    }
}

@Suite("Public API feasibility")
struct APITests {
    @Test func capabilitiesAdvertiseOnlyTheScalarProfile() throws {
        let encoder = try Encoder()
        let decoder = try Decoder()
        #expect(encoder.configuration.mode == .lossless)
        #expect(encoder.capabilities.formats == ["jpeg-xl"])
        #expect(encoder.capabilities.canEncode)
        #expect(decoder.capabilities.canDecode)
        #expect(decoder.capabilities.canInspect)
        #expect(try Transcoder().capabilities.isEmpty)
        #expect(EncodeOptions().copyPolicy == .requireSharedStorage)
        #expect(DecodeOptions().metadataPolicy == .preserve)
        #expect(TranscodeOptions().copyPolicy == .requireSharedStorage)
    }

    @Test func validatesConfigurationAndFiniteResourceLimits() {
        expectCodecError(.invalidArgument) { _ = try EncoderConfiguration(mode: .nearLossless(maximumAbsoluteError: 0)) }
        expectCodecError(.unsupportedFeature) { _ = try EncoderConfiguration(mode: .lossy) }
        expectCodecError(.unsupportedFeature) { _ = try TranscoderConfiguration(mode: .lossy) }
        for deadline in [Double.nan, Double.infinity, 0, -1] {
            expectCodecError(.invalidArgument) { _ = try ResourceLimits(deadlineSeconds: deadline) }
        }
        expectCodecError(.invalidArgument) { _ = try ResourceLimits(maximumWorkers: 0) }
        expectCodecError(.invalidArgument) { _ = try ResourceLimits(maximumDecodedBytes: -1) }
        #expect(ResourceLimits.watch.maximumDecodedBytes == 32 * 1024 * 1024)
        #expect(ResourceLimits.watch.maximumWorkers == 2)
    }

    @Test func admissionBoundariesAndMetadataAreChecked() throws {
        let limits = try ResourceLimits(maximumDecodedBytes: 4, maximumPixels: 2, maximumDimension: 2)
        let descriptor = try ImageDescriptor.greyscale16(width: 2, height: 1, limits: limits)
        _ = try ImageDestination.allocate(descriptor: descriptor, limits: limits)
        expectCodecError(.resourceLimitExceeded) {
            _ = try ImageDescriptor.greyscale16(width: 3, height: 1, limits: limits)
        }
        expectCodecError(.resourceLimitExceeded) { _ = try OwnedImageStorage(byteCount: 5, limits: limits) }
        let budget = try ResourceLimits(maximumMemoryBytes: 1)
        expectCodecError(.resourceLimitExceeded) { _ = try OwnedImageStorage(byteCount: 2, limits: budget) }
        let image = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { _, _ in 0 }
        expectCodecError(.invalidArgument) {
            _ = try Image(descriptor: descriptor, storage: image.storage,
                          metadata: ImageMetadata(requiredKeys: ["missing"]))
        }
        let iccLimits = try ResourceLimits(maximumICCBytes: 1)
        expectCodecError(.resourceLimitExceeded) {
            _ = try ImageDescriptor(width: 2, height: 1, planes: descriptor.planes,
                                    iccProfile: Data([0, 1]), limits: iccLimits)
        }
    }

    @Test func safeWriterRejectsOutOfRangeSamplesAndInvalidatesDestination() throws {
        let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1, meaningfulBits: 12)
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        expectCodecError(.invalidArgument) { _ = try destination.writeUInt16 { _, _ in 4096 } }
        expectCodecError(.storageUnavailable) { _ = try destination.writeUInt16 { _, _ in 0 } }
        expectCodecError(.storageUnavailable) { _ = try destination.storage.reserveWrite() }
        let valid = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { _, _ in 4095 }
        #expect(try valid.sampleUInt16(x: 0, y: 0) == 4095)
        expectCodecError(.invalidArgument) { _ = try valid.sampleUInt16(x: -1, y: 0) }
    }

    @Test func malformedInputRejectsWithoutTouchingDestination() async throws {
        let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1)
        let image = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { _, _ in 65535 }
        let encoder = try Encoder()
        let decoder = try Decoder()
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        expectCodecError(.malformedInput) { _ = try decoder.inspect(Data()) }
        _ = try await encoder.encode(image)
        await expectAsyncCodecError(.malformedInput) { _ = try await decoder.decode(Data()) }
        await expectAsyncCodecError(.malformedInput) { _ = try await decoder.decode(Data(), into: destination) }
        #expect(try destination.writeUInt16 { _, _ in 42 }.sampleUInt16(x: 0, y: 0) == 42)
        for target in TranscodeTarget.allCases {
            await expectAsyncCodecError(.unsupportedFeature) {
                _ = try await Transcoder().transcode(Data(), to: target)
            }
        }
    }

    @Test func rejectsInputLimitRequiredBackendAndDestructiveMetadataPolicy() async throws {
        let limit = try ResourceLimits(maximumCompressedBytes: 1)
        let decoder = try Decoder()
        expectCodecError(.resourceLimitExceeded) { _ = try decoder.inspect(Data([0, 1]), options: .init(resourceLimits: limit)) }
        await expectAsyncCodecError(.resourceLimitExceeded) {
            _ = try await Transcoder().transcode(Data([0, 1]), to: .jpegXL, options: .init(resourceLimits: limit))
        }
        await expectAsyncCodecError(.backendUnavailable) {
            _ = try await decoder.decode(Data(), options: .init(executionPolicy: .required(.accelerated)))
        }
        await expectAsyncCodecError(.invalidArgument) {
            _ = try await Transcoder().transcode(Data(), to: .jpegXL, options: .init(metadataPolicy: .discardAncillary))
        }
    }

    @Test func cancellationRetainsItsStandardErrorAndInvalidatesPartialWrite() async throws {
        let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 2)
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        let task = Task {
            do {
                _ = try destination.writeUInt16 { _, y in
                    if y == 0 { withUnsafeCurrentTask { $0?.cancel() } }
                    return 7
                }
                return false
            } catch is CancellationError { return true }
        }
        #expect(try await task.value)
        expectCodecError(.storageUnavailable) { _ = try destination.storage.reserveWrite() }
        let decoderTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await Decoder().decode(Data())
                return false
            } catch is CancellationError { return true }
        }
        #expect(try await decoderTask.value)
    }

    @Test func reportUnknownMeasurementsRemainUnknown() {
        let report = OperationReport(backend: .scalarCPU, fidelity: .exactSamples)
        #expect(report.pixelAllocationCount == nil)
        #expect(report.peakPixelBytes == nil)
        #expect(report.peakWorkspaceBytes == nil)
        #expect(report.elapsedSeconds == nil)
    }

    @Test func metadataSharesTheCallerAdmissionBudgetWithPixels() throws {
        let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 1)
        let image = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { _, _ in 7 }
        let metadata = ImageMetadata(entries: ["a": Data([1, 2])])
        let exact = try ResourceLimits(maximumDecodedBytes: 2, maximumMetadataBytes: 3, maximumMemoryBytes: 5)
        let accepted = try Image(descriptor: descriptor, storage: image.storage, metadata: metadata, limits: exact)
        #expect(accepted.metadata == metadata)
        let shortMetadata = try ResourceLimits(maximumMetadataBytes: 2)
        expectCodecError(.resourceLimitExceeded) {
            _ = try Image(descriptor: descriptor, storage: image.storage, metadata: metadata, limits: shortMetadata)
        }
        let shortMemory = try ResourceLimits(maximumMemoryBytes: 4)
        expectCodecError(.resourceLimitExceeded) {
            _ = try Image(descriptor: descriptor, storage: image.storage, metadata: metadata, limits: shortMemory)
        }
    }
}
