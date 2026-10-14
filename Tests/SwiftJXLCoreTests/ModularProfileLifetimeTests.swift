// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import SwiftJXL
@testable import SwiftJXLCore

private enum ProfileReadFault {
    @TaskLocal static var cancelAfterRead = false
}
private struct ProfileOwnerState: Sendable {
    var active = 0, finished = 0, destroyed = 0
}
/// Shares the actual sealed owner. Its borrow never escapes and all mutable
/// instrumentation is protected by Mutex; no unchecked concurrency is needed.
private final class ProfileOwnerCounter: Sendable {
    let value = Mutex(ProfileOwnerState())
}

private final class ProfileReadOwner: ReadOnlyImageStorage {
    let owner: any ReadOnlyImageStorage
    let state: ProfileOwnerCounter
    init(owner: any ReadOnlyImageStorage, state: ProfileOwnerCounter) {
        self.owner = owner; self.state = state
    }
    var byteCount: Int { owner.byteCount }
    var allocationID: UUID { owner.allocationID }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        state.value.withLock { $0.active += 1 }
        defer { state.value.withLock { $0.active -= 1; $0.finished += 1 } }
        let result = try owner.withUnsafeBytes(body)
        if ProfileReadFault.cancelAfterRead { withUnsafeCurrentTask { $0?.cancel() } }
        return result
    }
    deinit { state.value.withLock { $0.destroyed += 1 } }
}

struct ModularProfileLifetimeTests {
    private func source(_ f: ModularProfileCase, associated: Bool,
                        state: ProfileOwnerCounter) throws -> Image {
        // Reversed physical plane order, big endian, pixel/row gaps.
        let row = f.width * 4 + 8, planeBytes = row * f.height + 16
        let planes = try (0..<f.channels).map { c in
            let offset = 8 + (f.channels - 1 - c) * planeBytes
            return try PlaneDescriptor(width: f.width, height: f.height, components: [c],
                offset: offset, sampleStride: 2, pixelStride: 4, rowBytes: row,
                byteCount: offset + planeBytes)
        }
        let roles: [ComponentRole] = f.channels == 2 ? [.grey, .alpha] : [.red, .green, .blue, .alpha]
        let descriptor = try ImageDescriptor(width: f.width, height: f.height, meaningfulBits: f.bits,
            byteOrder: .bigEndian, components: roles, colour: f.channels == 2 ? .greyscale : .rgb,
            alpha: associated ? .premultiplied : .straight, planes: planes)
        let samples = f.pixels()
        let image = try ImageDestination.allocate(descriptor: descriptor).write { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0xA5)
            for c in 0..<f.channels { for i in 0..<(f.width * f.height) {
                let p = planes[c].offset + (i / f.width) * row + (i % f.width) * 4
                let value = associated && c < f.channels - 1 ? min(samples[c][i], samples[f.channels - 1][i]) : samples[c][i]
                bytes[p] = UInt8(value >> 8); bytes[p + 1] = UInt8(truncatingIfNeeded: value)
            } }
        }
        return try Image(descriptor: descriptor, storage: ProfileReadOwner(owner: image.storage, state: state))
    }

    @Test(arguments: [3, 6, 13], [false, true])
    func sharedSourceSurvivesCallerReleaseAndOneCancelledEncode(_ index: Int, _ associated: Bool) async throws {
        let f = ModularProfileCase.cases[index], state = ProfileOwnerCounter()
        var input: Image? = try source(f, associated: associated, state: state)
        let encoder = try Encoder(), decoder = try Decoder()
        let options = EncodeOptions(resourceLimits: try .init(maximumWorkers: 2))
        let expected = try await encoder.encode(try #require(input), options: options).data
        #if os(macOS) || os(Linux)
        if let binary = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"] {
            var pixels = f.pixels()
            if associated {
                for c in 0..<(f.channels - 1) { for i in pixels[c].indices {
                    pixels[c][i] = min(pixels[c][i], pixels[f.channels - 1][i])
                } }
            }
            try ModularProfileTests().oracle(expected, fixture: f, pixels: pixels, effort: 3, binary: binary)
        }
        #endif
        let identity = try #require(input).storage.allocationID
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for operation in 0..<4 {
                let retained = try #require(input)
                group.addTask {
                    let audit = ScalarStorageAudit()
                    do {
                        let result = try await ProfileReadFault.$cancelAfterRead.withValue(operation == 2) {
                            try await ScalarStorageAudit.$current.withValue(audit) {
                                try await encoder.encode(retained, options: operation == 3 ?
                                    .init(resourceLimits: .init(maximumWorkspaceBytes: 1)) : options)
                            }
                        }
                        #expect(operation < 2 && result.data == expected)
                        #expect(retained.storage.allocationID == identity)
                        #expect(result.report.copyEvents.isEmpty && audit.snapshot.finalPixelAllocations == 0)
                        let decoded = try await decoder.decode(result.data)
                        #expect(decoded.image.descriptor.meaningfulBits == f.bits)
                        #expect(decoded.image.descriptor.alpha == (associated ? .premultiplied : .straight))
                        // Different output layout must still feed exactly the same
                        // samples and interpretation back to the public encoder.
                        #expect(try await encoder.encode(decoded.image, options: options).data == expected)
                    } catch is CancellationError {
                        #expect(operation == 2)
                        // Cancellation occurs after the source borrow has run
                        // the real encoder, including its joined group workers.
                        #expect(audit.snapshot.workingPlaneAllocations > 0)
                    } catch let error as CodecError {
                        #expect(operation == 3 && error.category == .resourceLimitExceeded)
                        #expect(audit.snapshot.workingPlaneAllocations == 0)
                    }
                    #expect(state.value.withLock { $0.destroyed } == 0)
                    return operation
                }
            }
            input = nil // The caller releases its image while children retain it.
            var values: [Int] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(results.sorted() == [0, 1, 2, 3])
        let final = state.value.withLock { $0 }
        #expect(final.active == 0 && final.finished >= 4 && final.destroyed == 1)
    }
}
