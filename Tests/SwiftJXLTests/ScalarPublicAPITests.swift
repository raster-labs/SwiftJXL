// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import SwiftJXL

struct ScalarPublicAPITests {
    private func source() throws -> Image {
        let d = try ImageDescriptor.greyscale16(width: 7, height: 5, meaningfulBits: 12, rowBytes: 18, offset: 4)
        return try ImageDestination.allocate(descriptor: d).writeUInt16 { x, y in UInt16((x + y * 7) * 117) }
    }

    @Test func paddedBigEndianDestinationAndExactEncoderBytes() async throws {
        let image = try source()
        let encoded = try await Encoder().encode(image, options: .init(executionPolicy: .preferred(.accelerated)))
        #expect(encoded.report.fidelity == .exactSamples)
        #expect(encoded.report.backend == .scalarCPU && encoded.report.fallbackReason != nil)
        #expect(encoded.report.copyEvents.isEmpty)
        #expect(encoded.report.peakWorkspaceBytes == nil)
        let info = try Decoder().inspect(encoded.data)
        #expect(info.descriptor.meaningfulBits == 12 && info.frameCount == 1)
        let plane = try PlaneDescriptor(width: 7, height: 5, offset: 4, pixelStride: 4, rowBytes: 32, byteCount: 164)
        let d = try ImageDescriptor(width: 7, height: 5, meaningfulBits: 12, byteOrder: .bigEndian, planes: [plane])
        let owner = try OwnedImageStorage(byteCount: 164)
        let destination = try ImageDestination(descriptor: d, storage: owner)
        let decoded = try await Decoder().decode(encoded.data, into: destination)
        #expect(decoded.image.storage.allocationID == owner.allocationID)
        for y in 0..<5 { for x in 0..<7 {
            #expect(try decoded.image.sampleUInt16(x: x, y: y) == image.sampleUInt16(x: x, y: y))
        } }
        #expect(try await Encoder().encode(decoded.image).data == encoded.data)
    }

    @Test func resourceLimitsRejectBeforeDestinationWrite() async throws {
        let encoded = try await Encoder().encode(source())
        for limits in [try ResourceLimits(maximumWorkspaceBytes: 1),
                       try ResourceLimits(maximumMemoryBytes: encoded.data.count + 70),
                       try ResourceLimits(maximumDecodedBytes: 69),
                       try ResourceLimits(deadlineSeconds: Double.leastNonzeroMagnitude)] {
            let d = try ImageDescriptor.greyscale16(width: 7, height: 5, meaningfulBits: 12)
            let destination = try ImageDestination.allocate(descriptor: d)
            await expectAsyncCodecError(.resourceLimitExceeded) {
                _ = try await Decoder().decode(encoded.data, into: destination, options: .init(resourceLimits: limits))
            }
            #expect(try destination.writeUInt16 { _, _ in 1 }.sampleUInt16(x: 0, y: 0) == 1)
        }
        for limits in [try ResourceLimits(maximumWorkspaceBytes: 1),
                       try ResourceLimits(maximumMemoryBytes: 100),
                       try ResourceLimits(maximumCompressedBytes: 1)] {
            await expectAsyncCodecError(.resourceLimitExceeded) {
                _ = try await Encoder().encode(source(), options: .init(resourceLimits: limits))
            }
        }
        let exact = try ResourceLimits(maximumCompressedBytes: encoded.data.count)
        #expect(try await Encoder().encode(source(), options: .init(resourceLimits: exact)).data == encoded.data)
    }

    @Test func metadataMustBePreservedOrExplicitlyDiscarded() async throws {
        let image = try source()
        let metadata = ImageMetadata(entries: ["note": Data([1])])
        let ancillary = try Image(descriptor: image.descriptor, storage: image.storage, metadata: metadata)
        await expectAsyncCodecError(.unsupportedFeature) { _ = try await Encoder().encode(ancillary) }
        _ = try await Encoder().encode(ancillary, options: .init(metadataPolicy: .discardAncillary))
        let required = try Image(descriptor: image.descriptor, storage: image.storage,
            metadata: .init(entries: metadata.entries, requiredKeys: ["note"]))
        await expectAsyncCodecError(.unsupportedFeature) {
            _ = try await Encoder().encode(required, options: .init(metadataPolicy: .discardAncillary))
        }
    }

    @Test func progressIsSerialOutsideStorageBorrowAndCancellationIsPreserved() async throws {
        let image = try source()
        let phases = Mutex<[ProgressUpdate.Phase]>([])
        let encoded = try await Encoder().encode(image, options: .init(progress: { update in
            // Reentrant access would fail or deadlock if called under the provider lock.
            #expect((try? image.sampleUInt16(x: 0, y: 0)) == 0)
            phases.withLock { $0.append(update.phase) }
        }))
        #expect(phases.withLock { $0 } == [.processing, .completed])
        let task = Task {
            do {
                _ = try await Decoder().decode(encoded.data, options: .init(progress: { update in
                    if update.phase == .processing { withUnsafeCurrentTask { $0?.cancel() } }
                }))
                return false
            } catch is CancellationError { return true }
        }
        #expect(try await task.value)
    }
}
