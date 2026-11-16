// SPDX-License-Identifier: MIT
import Foundation
import Testing
import SwiftJXL
import SwiftJXLCore

@Suite("Synchronous APIs, extended VarDCT geometry, and 1T vs 8T parity")
struct ParallelAccelerationTests {
    private final class DataReadOnlyStorage: ReadOnlyImageStorage, Sendable {
        let data: Data
        let allocationID = UUID()
        var byteCount: Int { data.count }
        init(_ data: Data) { self.data = data }
        func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
            try data.withUnsafeBytes(body)
        }
    }

    private func makeGrey12Image(width: Int, height: Int) throws -> Image {
        var bytes = Data(count: width * height * 2)
        bytes.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt16.self) else { return }
            for y in 0..<height {
                let rowBase = y * width
                for x in 0..<width {
                    let v = UInt16(((x * 13 &+ y * 29 &+ ((x ^ y) & 63)) & 0x0FFF)).littleEndian
                    ptr[rowBase + x] = v
                }
            }
        }
        let descriptor = try ImageDescriptor.greyscale16(width: width, height: height, meaningfulBits: 12)
        return try Image(descriptor: descriptor, storage: DataReadOnlyStorage(bytes))
    }

    private func makeRGB8Image(width: Int, height: Int) throws -> Image {
        let rowBytes = width * 3
        let byteCount = rowBytes * height
        var bytes = Data(count: byteCount)
        bytes.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<height {
                let rowBase = y * rowBytes
                for x in 0..<width {
                    let off = rowBase + x * 3
                    ptr[off] = UInt8(truncatingIfNeeded: x &+ y * 3)
                    ptr[off + 1] = UInt8(truncatingIfNeeded: (x * 5) &+ y)
                    ptr[off + 2] = UInt8(truncatingIfNeeded: (x ^ y) &+ 77)
                }
            }
        }
        let plane = try PlaneDescriptor(
            width: width,
            height: height,
            components: [0, 1, 2],
            offset: 0,
            sampleStride: 1,
            pixelStride: 3,
            rowBytes: rowBytes,
            byteCount: byteCount
        )
        let descriptor = try ImageDescriptor(
            width: width,
            height: height,
            storageBits: 8,
            meaningfulBits: 8,
            components: [.red, .green, .blue],
            colour: .rgb,
            planes: [plane]
        )
        return try Image(descriptor: descriptor, storage: DataReadOnlyStorage(bytes))
    }

    @Test func modularLosslessSyncAndParallelBitExactParity() throws {
        let grey = try makeGrey12Image(width: 513, height: 513)
        let rgb = try makeRGB8Image(width: 513, height: 513)
        let encoder = try Encoder(configuration: .init(mode: .lossless))
        let decoder = try Decoder()

        let opt1 = EncodeOptions(resourceLimits: try ResourceLimits(maximumWorkers: 1))
        let opt8 = EncodeOptions(resourceLimits: try ResourceLimits(maximumWorkers: 8))
        let dec1 = DecodeOptions(resourceLimits: try ResourceLimits(maximumWorkers: 1))
        let dec8 = DecodeOptions(resourceLimits: try ResourceLimits(maximumWorkers: 8))

        for source in [grey, rgb] {
            let enc1 = try encoder.encodeSynchronously(source, options: opt1)
            let enc8 = try encoder.encodeSynchronously(source, options: opt8)
            #expect(enc1.data == enc8.data)

            let info = try decoder.inspectSynchronously(enc8.data, options: dec8)
            #expect(info.descriptor.width == source.descriptor.width)
            #expect(info.descriptor.height == source.descriptor.height)

            let out1 = try decoder.decodeSynchronously(enc8.data, options: dec1)
            let out8 = try decoder.decodeSynchronously(enc8.data, options: dec8)

            let dst1 = try ImageDestination.allocate(descriptor: source.descriptor)
            let dst8 = try ImageDestination.allocate(descriptor: source.descriptor)
            let outInto1 = try decoder.decodeSynchronously(enc8.data, into: dst1, options: dec1)
            let outInto8 = try decoder.decodeSynchronously(enc8.data, into: dst8, options: dec8)

            try source.storage.withUnsafeBytes { srcRaw in
                try out1.image.storage.withUnsafeBytes { raw1 in
                    try out8.image.storage.withUnsafeBytes { raw8 in
                        try outInto1.image.storage.withUnsafeBytes { rawInto1 in
                            try outInto8.image.storage.withUnsafeBytes { rawInto8 in
                                #expect(Data(raw1) == Data(raw8))
                                #expect(Data(rawInto1) == Data(srcRaw))
                                #expect(Data(rawInto8) == Data(srcRaw))
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func varDCTSyncParallelBitExactAndExtendedGeometryAbove4MiP() throws {
        let varOpts = try VarDCTEncodingOptions(distance: 1.0, strategySearch: .fixedDCT8)
        let encoder = try Encoder(configuration: .init(mode: .lossy, codecOptions: .init(varDCT: varOpts)))
        let decoder = try Decoder()

        let opt1 = EncodeOptions(resourceLimits: try ResourceLimits(maximumWorkers: 1, deadlineSeconds: 1800))
        let opt8 = EncodeOptions(resourceLimits: try ResourceLimits(maximumWorkers: 8, deadlineSeconds: 1800))
        let dec1 = DecodeOptions(resourceLimits: try ResourceLimits(maximumWorkers: 1, deadlineSeconds: 1800))
        let dec8 = DecodeOptions(resourceLimits: try ResourceLimits(maximumWorkers: 8, deadlineSeconds: 1800))

        // Multi-group 12-bit greyscale & 8-bit RGB 1T vs 8T exact parity
        for source in [try makeGrey12Image(width: 768, height: 512), try makeRGB8Image(width: 768, height: 512)] {
            let enc1 = try encoder.encodeSynchronously(source, options: opt1)
            let enc8 = try encoder.encodeSynchronously(source, options: opt8)
            #expect(enc1.data == enc8.data)

            let out1 = try decoder.decodeSynchronously(enc8.data, options: dec1)
            let out8 = try decoder.decodeSynchronously(enc8.data, options: dec8)
            try out1.image.storage.withUnsafeBytes { raw1 in
                try out8.image.storage.withUnsafeBytes { raw8 in
                    #expect(Data(raw1) == Data(raw8))
                }
            }
        }

        // Extended clinical geometry > 4 MiP (2500 x 2000 = 5,000,000 pixels, 12-bit greyscale)
        let large12 = try makeGrey12Image(width: 2500, height: 2000)
        let largeEnc = try encoder.encodeSynchronously(large12, options: opt8)
        #expect(largeEnc.report.fidelity == .lossy)
        let largeDec = try decoder.decodeSynchronously(largeEnc.data, options: dec8)
        #expect(largeDec.image.descriptor.width == 2500)
        #expect(largeDec.image.descriptor.height == 2000)
        #expect(largeDec.image.descriptor.meaningfulBits == 12)
    }

    @Test func jpegBridgeMultiGroupSyncAndParallelExactBitstreamRoundTrip() throws {
        // Load the real multi-group JPEGBridge fixture (`multigroup-420.jpg`) and verify 1T vs 8T synchronous transcoding parity.
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SwiftJXLCoreTests/Fixtures/JPEGBridge/multigroup-420.jpg")
        let jpegBytes = try Data(contentsOf: fixtureURL)

        let transcoder = try Transcoder()
        let opt1 = TranscodeOptions(resourceLimits: try ResourceLimits(maximumWorkers: 1))
        let opt8 = TranscodeOptions(resourceLimits: try ResourceLimits(maximumWorkers: 8))

        let jxl1 = try transcoder.transcodeSynchronously(jpegBytes, to: .jpegXL, options: opt1)
        let jxl8 = try transcoder.transcodeSynchronously(jpegBytes, to: .jpegXL, options: opt8)
        #expect(jxl1.data == jxl8.data)

        let restored1 = try transcoder.transcodeSynchronously(jxl8.data, to: .jpeg, options: opt1)
        let restored8 = try transcoder.transcodeSynchronously(jxl8.data, to: .jpeg, options: opt8)
        #expect(restored1.data == jpegBytes)
        #expect(restored8.data == jpegBytes)
    }

    @Test func transcoderAsyncCancellationPropagatesToParallelWorkers() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SwiftJXLCoreTests/Fixtures/JPEGBridge/multigroup-420.jpg")
        let jpegBytes = try Data(contentsOf: fixtureURL)
        let transcoder = try Transcoder()
        let opt8 = TranscodeOptions(resourceLimits: try ResourceLimits(maximumWorkers: 8))

        let preCancelled = Task { () throws -> EncodedImage in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transcoder.transcode(jpegBytes, to: .jpegXL, options: opt8)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await preCancelled.value
        }
    }
}
