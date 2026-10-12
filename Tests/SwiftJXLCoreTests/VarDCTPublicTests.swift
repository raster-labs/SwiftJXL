// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct VarDCTPublicTests {
    private func fixture(_ name: String, suffix: String = "jxl", directory: String = "VarDCT") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: suffix, subdirectory: directory))
        return try Data(contentsOf: url)
    }
    private func verify(_ image: Image, oracle: Data) throws {
        let d = image.descriptor, channels = d.components.count, maximum = Double((1 << d.meaningfulBits) - 1)
        let roles: [ComponentRole] = (d.colour == .greyscale ? [.grey] : [.red, .green, .blue]) +
            (d.alpha == .absent ? [] : [.alpha])
        let locations = try roles.map { role -> (PlaneDescriptor, Int) in
            let component = try #require(d.components.firstIndex(of: role))
            let plane = try #require(d.planes.first { $0.components.contains(component) })
            return (plane, try #require(plane.components.firstIndex(of: component)))
        }
        #expect(oracle.count == d.width * d.height * channels * 4)
        try image.storage.withUnsafeBytes { bytes in
            var peak = 0, squared = 0.0, count = 0
            var written = [Bool](repeating: false, count: bytes.count)
            for y in 0..<d.height { for x in 0..<d.width { for c in 0..<channels {
                let (plane, slot) = locations[c]
                let offset = plane.offset + y * plane.rowBytes + x * plane.pixelStride + slot * plane.sampleStride
                let actual: Int
                if d.storageBits == 8 { actual = Int(bytes[offset]); written[offset] = true }
                else {
                    actual = d.byteOrder == .littleEndian ? Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                        : Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                    written[offset] = true; written[offset + 1] = true
                }
                let i = ((y * d.width + x) * channels + c) * 4
                let raw = oracle.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: UInt32.self) }
                let reference = Double(Float(bitPattern: UInt32(littleEndian: raw)))
                let expected = Int((min(1, max(0, reference)) * maximum).rounded())
                let delta = abs(actual - expected)
                if roles[c] == .alpha { #expect(delta == 0) }
                else { peak = max(peak, delta); squared += Double(delta * delta); count += 1 }
            } } }
            // These are the separately recorded scalar-oracle corpus limits,
            // not universal JPEG XL conformance bounds or a replacement for NEON results.
            #expect(peak <= 2 && sqrt(squared / Double(count)) <= 0.5)
            #expect(bytes.indices.filter { !written[$0] }.allSatisfy { bytes[$0] == 0 })
        }
    }

    @Test(arguments: [17, 64], [1, 2, 3, 4])
    func publicAllocatingDecodePreservesReferenceAndReportsLossy(_ width: Int, _ channels: Int) async throws {
        let decoder = try Decoder()
        #expect(decoder.capabilities.compressionModes.contains(.lossy))
        #expect(Encoder.capabilities.compressionModes.contains(.lossy))
        for bits in [8, 16] { for independent in [false, true] {
            let name = "pred-\(width)-\(channels)-\(bits)" + (independent ? ".independent" : "")
            let data = try fixture(name), audit = ScalarStorageAudit()
            let info = try ScalarStorageAudit.$current.withValue(audit) { try decoder.inspect(data) }
            #expect(audit.snapshot.finalPixelAllocations == 0 && audit.snapshot.workingPlaneAllocations == 0)
            #expect(info.frameCount == 1 && info.descriptor.width == width && info.descriptor.meaningfulBits == bits)
            let decoded = try await ScalarStorageAudit.$current.withValue(audit) { try await decoder.decode(data) }
            #expect(decoded.report.fidelity == .lossy && decoded.report.copyEvents.isEmpty)
            #expect(audit.snapshot.finalPixelAllocations == 1)
            try verify(decoded.image, oracle: fixture(name, suffix: "scalar-oracle"))
        } }
    }

    @Test(arguments: [8, 16], [1, 2, 3, 4])
    func callerStorageRetainsIdentityRolesStridesAndByteOrder(_ bits: Int, _ channels: Int) async throws {
        let name = "pred-17-\(channels)-\(bits).independent", data = try fixture(name)
        let decoder = try Decoder(), info = try decoder.inspect(data), width = 17, height = 9, step = bits / 8
        let oracle = try fixture(name, suffix: "scalar-oracle")
        let roles = Array(info.descriptor.components.reversed())
        for planar in [false, true] { for littleEndian in [false, true] {
            let stride = planar ? step : channels * step, row = width * stride + 8, planeBytes = row * height + 12
            let planes = try (0..<(planar ? channels : 1)).map { c in
                try PlaneDescriptor(width: width, height: height,
                    components: planar ? [c] : Array(0..<channels), offset: 16 + c * planeBytes,
                    sampleStride: step, pixelStride: stride, rowBytes: row, byteCount: 16 + (c + 1) * planeBytes)
            }
            let descriptor = try ImageDescriptor(width: width, height: height, storageBits: bits, meaningfulBits: bits,
                byteOrder: littleEndian ? .littleEndian : .bigEndian, components: roles,
                colour: info.descriptor.colour, alpha: info.descriptor.alpha, planes: planes)
            let destination = try ImageDestination.allocate(descriptor: descriptor), audit = ScalarStorageAudit()
            let result = try await ScalarStorageAudit.$current.withValue(audit) {
                try await decoder.decode(data, into: destination, options: .init(copyPolicy: .requireSharedStorage))
            }
            #expect(result.image.storage.allocationID == destination.storage.allocationID)
            #expect(result.report.fidelity == .lossy && result.report.copyEvents.isEmpty)
            #expect(audit.snapshot.finalPixelAllocations == 0)
            try verify(result.image, oracle: oracle)
        } }
    }

    @Test func resourceAndInterpretationRejectionsStayDefined() async throws {
        let decoder = try Decoder(), data = try fixture("pred-17-1-8.independent")
        do {
            _ = try await decoder.decode(data, options: .init(resourceLimits: .init(maximumDecodedBytes: 1)))
            Issue.record("Pixel budget was ignored")
        } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
        let icc = try fixture("grayscale", directory: "VarDCT/Conformance")
        do { _ = try decoder.inspect(icc); Issue.record("ICC VarDCT was implicitly interpreted") }
        catch let error as CodecError { #expect(error.category == .unsupportedFeature) }
        do { _ = try await decoder.decode(Data(data.dropLast())); Issue.record("Truncated frame succeeded") }
        catch let error as CodecError { #expect(error.category == .malformedInput) }
    }

    @Test func cancellationBeforeSealingInvalidatesDestination() async throws {
        let decoder = try Decoder(), data = try fixture("pred-17-4-16.independent")
        let destination = try ImageDestination.allocate(descriptor: decoder.inspect(data).descriptor)
        let completed = Mutex(false)
        let task = Task {
            try await decoder.decode(data, into: destination, options: .init(progress: { update in
                if update.phase == .completed {
                    completed.withLock { $0 = true }
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }))
        }
        do { _ = try await task.value; Issue.record("Cancelled result published") }
        catch is CancellationError {}
        #expect(completed.withLock { $0 })
        #expect(throws: CodecError.self) { _ = try destination.write { _ in } }
    }
}
