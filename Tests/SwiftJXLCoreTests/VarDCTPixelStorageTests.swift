// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTPixelStorageTests {
    private func budget(_ bytes: Int = 64 * 1024 * 1024,
                        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(30))) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: bytes,
            maximumMemoryBytes: bytes, maximumDecodedBytes: bytes,
            maximumCompressedBytes: bytes, deadline: deadline)
    }
    private func fixture(_ name: String, extension suffix: String = "jxl") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: suffix, subdirectory: "VarDCT"))
        return try Data(contentsOf: url)
    }

    // Planar/interleaved, padded, little/big-endian storage all write directly
    // into one caller allocation. The oracle is the separately recorded scalar
    // numerical gate; this does not replace the original NEON evidence.
    @Test(arguments: [8, 16], [1, 2, 3, 4])
    func paddedOwningDestination(_ bits: Int, _ channels: Int) throws {
        let width = 17, height = 9, step = bits / 8
        let name = "pred-17-\(channels)-\(bits).independent"
        let source = try fixture(name), oracle = try fixture(name, extension: "scalar-oracle")
        for planar in [false, true] { for littleEndian in [false, true] {
            let operation = try budget()
            let envelope = try VarDCTFrameEnvelope.read(source, budget: operation)
            let pixelStride = planar ? step : channels * step
            let rowBytes = width * pixelStride + 7
            let planeBytes = rowBytes * height + 11
            let total = 13 + (planar ? channels * planeBytes : planeBytes)
            let layouts = try (0..<channels).map { c in
                try ModularChannelLayout(width: width, height: height,
                    offset: 13 + (planar ? c * planeBytes : c * step), rowBytes: rowBytes,
                    pixelStride: pixelStride, storageBits: bits, littleEndian: littleEndian)
            }
            var storage = [UInt8](repeating: 0xA5, count: total)
            let audit = ScalarStorageAudit()
            try ScalarStorageAudit.$current.withValue(audit) {
                try storage.withUnsafeMutableBytes { try VarDCTPixelDecoder.decode(envelope, into: $0, layouts: layouts) }
            }
            #expect(audit.snapshot.finalPixelAllocations == 0)
            var written = [Bool](repeating: false, count: total)
            var maxError = 0, squared = 0.0, count = 0
            for y in 0..<height { for x in 0..<width { for c in 0..<channels {
                let layout = layouts[c], offset = layout.offset + y * rowBytes + x * pixelStride
                for byte in 0..<step { written[offset + byte] = true }
                let actual: Int
                if step == 1 { actual = Int(storage[offset]) }
                else if littleEndian { actual = Int(storage[offset]) | Int(storage[offset + 1]) << 8 }
                else { actual = Int(storage[offset]) << 8 | Int(storage[offset + 1]) }
                let oracleOffset = ((y * width + x) * channels + c) * 4
                let raw = oracle.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: oracleOffset, as: UInt32.self) }
                let value = Double(Float(bitPattern: UInt32(littleEndian: raw)))
                let expected = Int((min(1, max(0, value)) * Double((1 << bits) - 1)).rounded())
                let error = abs(actual - expected)
                if channels % 2 == 0 && c == channels - 1 { #expect(error == 0) }
                else { maxError = max(maxError, error); squared += Double(error * error); count += 1 }
            } } }
            #expect(maxError <= 2)
            #expect(sqrt(squared / Double(count)) <= 0.5)
            #expect(storage.indices.filter { !written[$0] }.allSatisfy { storage[$0] == 0xA5 })
        } }
    }

    @Test func rejectsInvalidDestinationBeforeWriting() throws {
        let source = try fixture("pred-17-1-16.independent")
        let operation = try budget()
        let envelope = try VarDCTFrameEnvelope.read(source, budget: operation)
        let narrow = try ModularChannelLayout(width: 17, height: 9, offset: 0,
            rowBytes: 17, pixelStride: 1, storageBits: 8, littleEndian: true)
        let valid = try ModularChannelLayout(width: 17, height: 9, offset: 0,
            rowBytes: 34, pixelStride: 2, storageBits: 16, littleEndian: true)
        var storage = [UInt8](repeating: 0xA5, count: 306)
        #expect(throws: (any Error).self) {
            try storage.withUnsafeMutableBytes { try VarDCTPixelDecoder.decode(envelope, into: $0, layouts: [narrow]) }
        }
        #expect(throws: (any Error).self) {
            try storage.withUnsafeMutableBytes {
                try VarDCTPixelDecoder.decode(envelope, into: UnsafeMutableRawBufferPointer(rebasing: $0[..<305]), layouts: [valid])
            }
        }
        #expect(throws: (any Error).self) {
            try storage.withUnsafeMutableBytes { try VarDCTPixelDecoder.decode(envelope, into: $0, layouts: []) }
        }
        #expect(storage.allSatisfy { $0 == 0xA5 })
    }

    @Test func cancellationRejectsBeforeWriting() async throws {
        let source = try fixture("pred-17-1-8.independent")
        let envelope = try VarDCTFrameEnvelope.read(source, budget: budget())
        let layout = try ModularChannelLayout(width: 17, height: 9, offset: 0,
            rowBytes: 17, pixelStride: 1, storageBits: 8, littleEndian: true)
        let task = Task {
            var storage = [UInt8](repeating: 0xA5, count: 153)
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try storage.withUnsafeMutableBytes { try VarDCTPixelDecoder.decode(envelope, into: $0, layouts: [layout]) }
                Issue.record("Cancelled decode succeeded")
            } catch is CancellationError {
                #expect(storage.allSatisfy { $0 == 0xA5 })
            }
        }
        try await task.value
    }
}
