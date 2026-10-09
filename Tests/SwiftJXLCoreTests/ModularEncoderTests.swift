// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct ModularEncoderTests {
    private func budget() throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 1024 * 1024,
            maximumWorkspaceBytes: 512 * 1024 * 1024, maximumMemoryBytes: 768 * 1024 * 1024,
            maximumDecodedBytes: 64 * 1024 * 1024, maximumCompressedBytes: 4 * 1024 * 1024,
            deadline: .now.advanced(by: .seconds(120)))
    }
    @Test(arguments: [1, 2, 3, 4], [8, 12, 16])
    func groupedBorrowedSource(_ channels: Int, _ bits: Int) async throws {
        for width in [31, 513, 1025, 4097] {
            let height = 3, sampleBytes = bits == 8 ? 1 : 2
            let stride = channels * sampleBytes + 2, row = width * stride + 4
            var bytes = [UInt8](repeating: 0xA5, count: height * row + 8)
            let layouts = try (0..<channels).map { c in
                try ModularChannelLayout(width: width, height: height, offset: 4 + c * sampleBytes,
                    rowBytes: row, pixelStride: stride, storageBits: sampleBytes * 8, littleEndian: false)
            }
            let maximum = (1 << bits) - 1
            var expected = [[Int32]](repeating: [], count: channels)
            for c in 0..<channels { for i in 0..<(width * height) {
                let value = (i * 71 + (i / width) * 37 + c * 113) & maximum
                expected[c].append(Int32(value))
                let p = layouts[c].offset + (i / width) * row + (i % width) * stride
                bytes[p] = UInt8(truncatingIfNeeded: bits == 8 ? value : value >> 8)
                if sampleBytes == 2 { bytes[p + 1] = UInt8(truncatingIfNeeded: value) }
            } }
            let original = bytes
            let encoded = try bytes.withUnsafeBytes {
                try ModularStorageEncoder.encode($0, layouts: layouts, bitsPerSample: bits,
                    grayscale: channels < 3, alphaAssociated: channels % 2 == 0 ? false : nil,
                    renderingIntent: .relative, budget: budget())
            }
            #expect(bytes == original)
            let roles: [ComponentRole] = (channels < 3 ? [.grey] : [.red, .green, .blue]) +
                (channels % 2 == 0 ? [.alpha] : [])
            let plane = try PlaneDescriptor(width: width, height: height, components: Array(roles.indices),
                offset: 4, sampleStride: sampleBytes, pixelStride: stride, rowBytes: row, byteCount: bytes.count)
            let descriptor = try ImageDescriptor(width: width, height: height, storageBits: sampleBytes * 8,
                meaningfulBits: bits, byteOrder: .bigEndian, components: roles, colour: channels < 3 ? .greyscale : .rgb,
                alpha: channels % 2 == 0 ? .straight : .absent, planes: [plane])
            let image = try ImageDestination.allocate(descriptor: descriptor).write { destination in
                for i in bytes.indices { destination[i] = bytes[i] }
            }
            let audit = ScalarStorageAudit()
            let publicEncoded = try await ScalarStorageAudit.$current.withValue(audit) { try await Encoder().encode(image) }
            #expect(publicEncoded.data == encoded)
            #expect(publicEncoded.report.copyEvents.isEmpty && audit.snapshot.finalPixelAllocations == 0)
            #expect(try image.storage.withUnsafeBytes { Array($0) } == original)
            let decoded = try ModularFrameDecoder.decode(encoded, budget: budget())
            #expect(decoded.bitsPerSample == bits)
            #expect(decoded.image.channels.map(\.pixels) == expected)
            #if os(macOS) || os(Linux)
            if let binary = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"] {
                try oracle(encoded, expected: expected, width: width, height: height, bits: bits, binary: binary)
            }
            #endif
        }
    }
    @Test(arguments: [2, 4], [8, 12, 16])
    func associatedAlphaAndRenderingIntent(_ channels: Int, _ bits: Int) async throws {
        let width = 31, height = 17, maximum = (1 << bits) - 1
        let roles: [ComponentRole] = (channels == 2 ? [.grey] : [.red, .green, .blue]) + [.alpha]
        let plane = try PlaneDescriptor(width: width, height: height, components: Array(roles.indices),
            sampleStride: 2, pixelStride: channels * 2, rowBytes: width * channels * 2, byteCount: width * height * channels * 2)
        let descriptor = try ImageDescriptor(width: width, height: height, meaningfulBits: bits,
            components: roles, colour: channels == 2 ? .greyscale : .rgb, alpha: .premultiplied, planes: [plane])
        var expected = [[Int32]](repeating: [], count: channels)
        for i in 0..<(width * height) {
            let alpha = (i * 211) & maximum
            for c in 0..<channels { expected[c].append(Int32(c == channels - 1 ? alpha : alpha * (c + 1) / channels)) }
        }
        let pixels = try ImageDestination.allocate(descriptor: descriptor).write { bytes in
            for i in 0..<(width * height) { for c in 0..<channels {
                let p = (i * channels + c) * 2, value = expected[c][i]
                bytes[p] = UInt8(truncatingIfNeeded: value)
                bytes[p + 1] = UInt8(truncatingIfNeeded: value >> 8)
            } }
        }
        let metadata = SwiftJXL.ImageMetadata(entries: ["jpegXL.renderingIntent": Data([UInt8(RenderingIntent.saturation.rawValue)])],
                                             requiredKeys: ["jpegXL.renderingIntent"])
        let image = try Image(descriptor: descriptor, storage: pixels.storage, metadata: metadata)
        let encoded = try await Encoder().encode(image)
        let info = try Decoder().inspect(encoded.data)
        #expect(info.descriptor.alpha == .premultiplied && info.metadata == metadata)
        let decoded = try ModularFrameDecoder.decode(encoded.data, budget: budget())
        #expect(decoded.alphaAssociated == true && decoded.renderingIntent == .saturation)
        #expect(decoded.image.channels.map(\.pixels) == expected)
        #if os(macOS) || os(Linux)
        if let binary = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"] {
            try oracle(encoded.data, expected: expected, width: width, height: height, bits: bits, binary: binary)
        }
        #endif
    }

    #if os(macOS) || os(Linux)
    private func oracle(_ encoded: Data, expected: [[Int32]], width: Int, height: Int, bits: Int, binary: String) throws {
        let root = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("modular-encode-\(width)-\(expected.count)-\(bits)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { if ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_OUTPUT"] == nil { try? FileManager.default.removeItem(at: dir) } }
        let input = dir.appendingPathComponent("native.jxl"), output = dir.appendingPathComponent("oracle.pam")
        try encoded.write(to: input)
        let log = dir.appendingPathComponent("oracle.log")
        #expect(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary + "/djxl")
        process.arguments = [input.path, output.path, "--bits_per_sample=\(bits)", "--num_threads=2", "--quiet"]
        process.standardOutput = handle; process.standardError = handle
        try process.run(); process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Independent decoder failed; inspect oracle.log")
        let pam = try Data(contentsOf: output)
        var pixels = Data()
        for i in 0..<(width * height) { for c in expected.indices {
            let value = expected[c][i]
            if bits > 8 { pixels.append(UInt8(truncatingIfNeeded: value >> 8)) }
            pixels.append(UInt8(truncatingIfNeeded: value))
        } }
        let headerCount = pam.count - pixels.count
        try #require(headerCount > 0)
        let header = String(decoding: pam.prefix(headerCount), as: UTF8.self)
        #expect(header.contains("MAXVAL \((1 << bits) - 1)") || header.hasSuffix("\((1 << bits) - 1)\n"))
        #expect(pam.suffix(pixels.count) == pixels)
    }
    #endif
}
