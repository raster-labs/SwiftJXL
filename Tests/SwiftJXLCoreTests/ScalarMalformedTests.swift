// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct ScalarMalformedTests {
    private func fixture() throws -> Data {
        try SpecModularEncoder.encodeGrayscale16(width: 8, height: 8, bitsPerSample: 12,
            pixelsInt32: (0..<64).map { Int32($0 * 61) }, effort: 3)
    }

    @Test func everyTruncatedPrefixAndTrailingBytesAreRejected() throws {
        let encoded = try fixture()
        for count in 0..<encoded.count {
            #expect(throws: (any Error).self) { try ScalarModularDecoder.decode(Data(encoded.prefix(count))) }
        }
        var extended = encoded; extended.append(0)
        #expect(throws: (any Error).self) { try ScalarModularDecoder.decode(extended) }
    }

    @Test func deterministicSingleBitMutationsDoNotTrap() throws {
        let encoded = try fixture()
        for index in encoded.indices {
            for shift in 0..<8 {
                var mutation = encoded; mutation[index] ^= 1 << shift
                do {
                    let result = try ScalarModularDecoder.decode(mutation)
                    #expect(result.pixels.count == result.width * result.height)
                    #expect(result.pixels.allSatisfy { $0 >= 0 && $0 < (1 << result.bitsPerSample) })
                } catch {
                    // Malformed and unsupported inputs must fail by throwing, not trapping.
                }
            }
        }
    }

    @Test func storageSlicesAndExtremeReaderOffsets() throws {
        let expected = try fixture()
        var prefixed = Data([0, 0, 0]); prefixed.append(expected)
        let slice = prefixed.dropFirst(3)
        #expect(slice.startIndex == 3)
        #expect(try ScalarModularDecoder.decode(slice).pixels == ScalarModularDecoder.decode(expected).pixels)
        for offset in [-1, Int.min, Int.max] {
            var reader = BitReader(expected, startingAt: offset)
            #expect(throws: (any Error).self) { try reader.readBit() }
            #expect(throws: (any Error).self) { try reader.peek(bits: 1) }
            #expect(throws: (any Error).self) { try reader.skip(bits: Int.max) }
        }
    }

    @Test func encoderRejectsSamplesOutsideDeclaredPrecision() {
        for value: Int32 in [-1, 4096, Int32.min, Int32.max] {
            #expect(throws: (any Error).self) {
                try SpecModularEncoder.encodeGrayscale16(width: 1, height: 1,
                    bitsPerSample: 12, pixelsInt32: [value], effort: 3)
            }
        }
    }

    @Test func cancelledDecodeThrowsCancellationError() async throws {
        let data = try fixture()
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try ScalarModularDecoder.decode(data) }
        }
        await operation.value
    }

    @Test func containerRejectsOverflowAndAmbiguousCodestreams() throws {
        let signature = Data(jxlContainerSignature)
        let ftyp = box("ftyp", Data("jxl \0\0\0\0jxl ".utf8))
        let stream = try fixture()
        var valid = signature + ftyp + box("jxlc", stream)
        #expect(try ScalarModularDecoder.decode(valid).pixels.count == 64)
        var prefixed = Data([0, 0, 0]); prefixed.append(valid)
        #expect(try ScalarModularDecoder.decode(prefixed.dropFirst(3)).pixels.count == 64)
        valid += box("jxlc", stream)
        #expect(throws: (any Error).self) { try ScalarModularDecoder.decode(valid) }
        let huge = signature + ftyp + Data([0, 0, 0, 1]) + Data("jxlc".utf8) + Data(repeating: 0xff, count: 8)
        #expect(throws: (any Error).self) { try ScalarModularDecoder.decode(huge) }
        for sequence: UInt32 in [1, 0x8000_0001, 0] {
            let partial = signature + ftyp + box("jxlp", bigEndian(sequence) + stream)
            #expect(throws: (any Error).self) { try ScalarModularDecoder.decode(partial) }
        }
        let single = signature + ftyp + box("jxlp", bigEndian(0x8000_0000) + stream)
        #expect(try ScalarModularDecoder.decode(single).pixels.count == 64)
        let mixed = single + box("jxlc", stream)
        #expect(throws: (any Error).self) { try ScalarModularDecoder.decode(mixed) }
    }

    private func bigEndian(_ value: UInt32) -> Data {
        Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
    }
    private func box(_ type: String, _ payload: Data) -> Data {
        bigEndian(UInt32(payload.count + 8)) + Data(type.utf8) + payload
    }
}
