// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct ScalarStorageTests {
    @Test(arguments: [9, 12, 16], [true, false])
    func writesCallerAllocationWithPaddingAndByteOrder(bits: Int, littleEndian: Bool) throws {
        let width = 7, height = 5, offset = 4, stride = 4, rowBytes = 36
        let capacity = offset + height * rowBytes + 8
        let plane = try PlaneDescriptor(width: width, height: height, offset: offset,
            pixelStride: stride, rowBytes: rowBytes, byteCount: capacity)
        let descriptor = try ImageDescriptor(width: width, height: height, meaningfulBits: bits,
            byteOrder: littleEndian ? .littleEndian : .bigEndian, planes: [plane])
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        let allocationID = destination.storage.allocationID
        let maximum = (Int32(1) << bits) - 1
        var samples = (0..<(width * height)).map { Int32($0 * 1999) & maximum }
        samples[0] = 0; samples[1] = maximum
        let encoded = try SpecModularEncoder.encodeGrayscale16(width: width, height: height,
            bitsPerSample: UInt32(bits), pixelsInt32: samples, effort: 3)
        let frame = try ScalarModularDecoder.prepare(encoded)
        let layout = try ScalarPlaneLayout(width: width, height: height, offset: offset,
            rowBytes: rowBytes, pixelStride: stride, littleEndian: littleEndian)
        var writeAddress: UInt?
        let result = try destination.write { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0xa5)
            writeAddress = raw.baseAddress.map { UInt(bitPattern: $0) }
            try frame.decode(into: raw, layout: layout)
        }
        #expect(result.storage.allocationID == allocationID)
        var expected = [UInt8](repeating: 0xa5, count: capacity)
        for y in 0..<height {
            for x in 0..<width {
                let sample = UInt16(samples[y * width + x])
                let position = offset + y * rowBytes + x * stride
                expected[position] = UInt8(truncatingIfNeeded: littleEndian ? sample : sample >> 8)
                expected[position + 1] = UInt8(truncatingIfNeeded: littleEndian ? sample >> 8 : sample)
                #expect(try result.sampleUInt16(x: x, y: y) == sample)
            }
        }
        let reencoded = try result.storage.withUnsafeBytes { raw in
            try ScalarModularEncoder.encode(raw, layout: layout, bitsPerSample: bits)
        }
        #expect(reencoded == encoded)
        try result.storage.withUnsafeBytes { raw in
            #expect(raw.baseAddress.map { UInt(bitPattern: $0) } == writeAddress)
            #expect(Array(raw) == expected)
        }
    }

    @Test func concurrentEncodersShareOneImmutableSource() async throws {
        let descriptor = try ImageDescriptor.greyscale16(width: 31, height: 17, meaningfulBits: 12, rowBytes: 66)
        let source = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { x, y in
            UInt16((x * 37 + y * 163) & 4095)
        }
        let layout = try ScalarPlaneLayout(width: 31, height: 17, rowBytes: 66)
        let expected = try source.storage.withUnsafeBytes { raw in
            try ScalarModularEncoder.encode(raw, layout: layout, bitsPerSample: 12)
        }
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try source.storage.withUnsafeBytes { raw in
                        try ScalarModularEncoder.encode(raw, layout: layout, bitsPerSample: 12)
                    }
                }
            }
            for try await encoded in group { #expect(encoded == expected) }
        }
        #expect(try ScalarModularDecoder.prepare(expected).bitsPerSample == 12)
    }

    @Test func rejectsShortDestinationBeforeWriting() throws {
        let encoded = try SpecModularEncoder.encodeGrayscale16(width: 2, height: 2,
            pixelsInt32: [0, 1, 65535, 9], effort: 3)
        let frame = try ScalarModularDecoder.prepare(encoded)
        let layout = try ScalarPlaneLayout(width: 2, height: 2, rowBytes: 4)
        var bytes = [UInt8](repeating: 0xa5, count: 7)
        _ = bytes.withUnsafeMutableBytes { raw in
            #expect(throws: (any Error).self) { try frame.decode(into: raw, layout: layout) }
        }
        #expect(bytes == [UInt8](repeating: 0xa5, count: 7))
        #expect(throws: (any Error).self) {
            try ScalarPlaneLayout(width: 2, height: 2, offset: Int.max, rowBytes: 4)
        }
        #expect(throws: (any Error).self) {
            try ScalarPlaneLayout(width: 2, height: 2, rowBytes: Int.max)
        }
    }

    @Test func cancellationInvalidatesCallerDestination() async throws {
        let encoded = try SpecModularEncoder.encodeGrayscale16(width: 1, height: 2,
            pixelsInt32: [1, 2], effort: 3)
        let frame = try ScalarModularDecoder.prepare(encoded)
        let descriptor = try ImageDescriptor.greyscale16(width: 1, height: 2)
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        let layout = try ScalarPlaneLayout(width: 1, height: 2, rowBytes: 2)
        let operation = Task {
            #expect(throws: CancellationError.self) {
                try destination.write { raw in
                    withUnsafeCurrentTask { $0?.cancel() }
                    try frame.decode(into: raw, layout: layout)
                }
            }
        }
        _ = await operation.value
        #expect(throws: CodecError.self) { try destination.storage.reserveWrite() }
    }
}
