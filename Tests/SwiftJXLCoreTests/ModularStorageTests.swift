// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct ModularStorageTests {
    private struct Fixture: Decodable { let name: String; let width: Int, height: Int, channels: Int, bits: Int }
    private func budget(decoded: Int = 64 * 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 4 * 1024 * 1024,
            maximumWorkspaceBytes: 512 * 1024 * 1024, maximumMemoryBytes: 768 * 1024 * 1024,
            maximumDecodedBytes: decoded, maximumCompressedBytes: 4 * 1024 * 1024,
            deadline: .now.advanced(by: .seconds(120)))
    }
    private func fixture(_ name: String) throws -> (Fixture, Data) {
        let url = try #require(Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Modular/Decoder"))
        let entries = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        let entry = try #require(entries.first { $0.name == name })
        let file = try #require(Bundle.module.url(forResource: name, withExtension: "jxl", subdirectory: "Modular/Decoder"))
        return (entry, try Data(contentsOf: file))
    }

    @Test(arguments: ["gray8", "grayalpha8", "grayalpha16", "rgb8", "rgba8", "rgb12", "rgba16",
                      "groups-rgb8", "groups-rgba16", "groups-grayalpha16", "responsive-gray8", "responsive-rgb8",
                      "responsive-wide-rgb8", "responsive-small-rgb8", "palette-rgb8", "palette-rgb16"],
          [0, 1, 2])
    func paddedCallerStorage(_ name: String, _ variant: Int) throws {
        let (f, data) = try fixture(name)
        let audit = ScalarStorageAudit()
        try ScalarStorageAudit.$current.withValue(audit) {
            let plan = try ModularFrameDecoder.prepare(data, budget: budget())
            #expect(audit.snapshot.workingPlaneAllocations == 0)
            #expect(audit.snapshot.finalPixelAllocations == 0)
            let bytesPerSample = variant == 0 && f.bits == 8 ? 1 : 2
            let planar = variant == 2, little = variant != 1
            let stride = (planar ? 1 : f.channels) * bytesPerSample + 2
            let row = f.width * stride + 8, planeBytes = f.height * row + 8
            let count = 16 + (planar ? f.channels : 1) * planeBytes
            let layouts = try (0..<f.channels).map { c in
                try ModularChannelLayout(width: f.width, height: f.height,
                    offset: 8 + (planar ? (f.channels - 1 - c) * planeBytes : (f.channels - 1 - c) * bytesPerSample),
                    rowBytes: row, pixelStride: stride, storageBits: bytesPerSample * 8, littleEndian: little)
            }
            var actual = [UInt8](repeating: 0xA5, count: count), expected = actual
            for c in 0..<f.channels { for i in 0..<(f.width * f.height) {
                let value = (name.hasPrefix("palette-") ? (i % 4) * 47 + c * 31 : i * 71 + (i / f.width) * 37 + c * 113) & ((1 << f.bits) - 1)
                let p = layouts[c].offset + (i / f.width) * row + (i % f.width) * stride
                expected[p] = UInt8(truncatingIfNeeded: bytesPerSample == 1 || little ? value : value >> 8)
                if bytesPerSample == 2 { expected[p + 1] = UInt8(truncatingIfNeeded: little ? value >> 8 : value) }
            } }
            try actual.withUnsafeMutableBytes { try plan.decode(into: $0, layouts: layouts) }
            #expect(actual == expected) // Includes every padding/gap/guard byte.
            #expect(audit.snapshot.finalPixelAllocations == 0)
            if ["gray8", "grayalpha8", "grayalpha16", "groups-grayalpha16"].contains(name) {
                #expect(audit.snapshot.workingPlaneAllocations == 0)
            } else { #expect(audit.snapshot.workingPlaneAllocations > 0) }
        }
    }

    @Test func eightBitAdmissionUsesActualCallerCapacity() throws {
        let (f, data) = try fixture("gray8")
        let bytes = f.width * f.height
        let plan = try ModularFrameDecoder.prepare(data, budget: budget(decoded: bytes))
        let layout = try ModularChannelLayout(width: f.width, height: f.height, offset: 0,
            rowBytes: f.width, pixelStride: 1, storageBits: 8, littleEndian: true)
        var output = [UInt8](repeating: 0, count: bytes)
        try output.withUnsafeMutableBytes { try plan.decode(into: $0, layouts: [layout]) }
        #expect(output[1] == 71)
    }

    @Test func mismatchedPrecisionOrCapacityRejectsBeforeTouchingBytes() throws {
        let (f, data) = try fixture("grayalpha16")
        let plan = try ModularFrameDecoder.prepare(data, budget: budget())
        let layouts = try (0..<2).map { c in
            try ModularChannelLayout(width: f.width, height: f.height, offset: c,
                rowBytes: f.width * 2, pixelStride: 2, storageBits: 8, littleEndian: true)
        }
        var output = [UInt8](repeating: 0xA5, count: f.width * f.height * 2)
        output.withUnsafeMutableBytes { raw in
            _ = #expect(throws: ScalarModularError.self) { try plan.decode(into: raw, layouts: layouts) }
        }
        #expect(output.allSatisfy { $0 == 0xA5 })
        #expect(throws: ScalarModularError.self) {
            try ModularChannelLayout(width: 10, height: 2, offset: Int.max, rowBytes: 20,
                                     pixelStride: 2, storageBits: 16, littleEndian: true)
        }
    }
    @Test(arguments: ["grayalpha8", "grayalpha16", "rgb8", "rgba16", "rgb12", "groups-rgb8",
                      "groups-rgba16", "groups-grayalpha16", "responsive-wide-rgb8", "palette-rgb16"], [false, true])
    func publicOwningColourDestination(_ name: String, _ planar: Bool) async throws {
        let (f, data) = try fixture(name)
        let roles: [ComponentRole] = (f.channels < 3 ? [.grey] : [.red, .green, .blue]) + (f.channels % 2 == 0 ? [.alpha] : [])
        let storageBits = f.bits == 8 ? 8 : 16
        let sampleBytes = storageBits / 8, stride = (planar ? 1 : f.channels) * 4 + 4
        let row = f.width * stride + 8, planeBytes = f.height * row + 16
        let capacity = 16 + (planar ? f.channels : 1) * planeBytes
        let planes: [PlaneDescriptor]
        if planar {
            planes = try (0..<f.channels).map { c in
                try PlaneDescriptor(width: f.width, height: f.height, components: [c],
                    offset: 8 + c * planeBytes, sampleStride: sampleBytes, pixelStride: stride,
                    rowBytes: row, byteCount: 8 + (c + 1) * planeBytes)
            }
        } else {
            planes = [try PlaneDescriptor(width: f.width, height: f.height, components: Array(roles.indices.reversed()),
                offset: 8, sampleStride: 4, pixelStride: stride, rowBytes: row, byteCount: capacity)]
        }
        let descriptor = try ImageDescriptor(width: f.width, height: f.height, storageBits: storageBits,
            meaningfulBits: f.bits, byteOrder: .bigEndian, components: roles,
            colour: f.channels < 3 ? .greyscale : .rgb, alpha: f.channels % 2 == 0 ? .straight : .absent, planes: planes)
        let owner = try OwnedImageStorage(byteCount: capacity)
        let destination = try ImageDestination(descriptor: descriptor, storage: owner)
        let audit = ScalarStorageAudit()
        let result = try await ScalarStorageAudit.$current.withValue(audit) {
            let info = try Decoder().inspect(data)
            #expect(info.descriptor.components == roles && info.descriptor.meaningfulBits == f.bits)
            #expect(audit.snapshot.workingPlaneAllocations == 0 && audit.snapshot.finalPixelAllocations == 0)
            return try await Decoder().decode(data, into: destination)
        }
        #expect(result.image.storage.allocationID == owner.allocationID)
        #expect(result.report.copyEvents.isEmpty && result.report.fidelity == .exactSamples)
        #expect(audit.snapshot.finalPixelAllocations == 0)
        let allocated = try await Decoder().decode(data)
        var expected = [UInt8](repeating: 0, count: capacity)
        for c in 0..<f.channels { for i in 0..<(f.width * f.height) {
            let value = (name.hasPrefix("palette-") ? (i % 4) * 47 + c * 31 : i * 71 + (i / f.width) * 37 + c * 113) & ((1 << f.bits) - 1)
            let offset = (planar ? 8 + c * planeBytes : 8 + (f.channels - 1 - c) * 4) + (i / f.width) * row + (i % f.width) * stride
            expected[offset] = UInt8(truncatingIfNeeded: storageBits == 8 ? value : value >> 8)
            if storageBits == 16 { expected[offset + 1] = UInt8(truncatingIfNeeded: value) }
        } }
        #expect(try result.image.storage.withUnsafeBytes { Array($0) } == expected)
        try allocated.image.storage.withUnsafeBytes { bytes in
            var matches = true
            for i in 0..<(f.width * f.height) { for c in 0..<f.channels {
                let p = (i * f.channels + c) * 2
                let value = Int(bytes[p]) | (Int(bytes[p + 1]) << 8)
                let expected = (name.hasPrefix("palette-") ? (i % 4) * 47 + c * 31 : i * 71 + (i / f.width) * 37 + c * 113) & ((1 << f.bits) - 1)
                if value != expected { matches = false }
            } }
            #expect(matches)
        }
    }

    @Test func alphaMismatchRejectsBeforeWritingAndMalformedPixelsInvalidate() async throws {
        let (_, rgba) = try fixture("rgba16")
        let good = try Decoder().inspect(rgba).descriptor
        let wrong = try ImageDescriptor(width: good.width, height: good.height, meaningfulBits: 16,
            components: good.components, colour: .rgb, alpha: .premultiplied, planes: good.planes)
        let destination = try ImageDestination.allocate(descriptor: wrong)
        do {
            _ = try await Decoder().decode(rgba, into: destination)
            Issue.record("Alpha mismatch was accepted")
        } catch let error as CodecError { #expect(error.category == .incompatibleImageLayout) }
        _ = try destination.write { bytes in bytes.initializeMemory(as: UInt8.self, repeating: 0) }

        let (_, gray) = try fixture("gray8")
        var damaged = gray
        damaged[damaged.count - 1] ^= 0x80
        let info = try Decoder().inspect(damaged)
        let invalidated = try ImageDestination.allocate(descriptor: info.descriptor)
        do {
            _ = try await Decoder().decode(damaged, into: invalidated)
            Issue.record("Damaged pixel payload was accepted")
        } catch let error as CodecError { #expect(error.category == .malformedInput) }
        #expect(throws: CodecError.self) { try invalidated.writeUInt16 { _, _ in 0 } }
    }

}
