// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct VarDCTPublicEncoderTests {
    private func fixture(_ name: String, suffix: String, directory: String = "VarDCT") throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: suffix, subdirectory: directory)))
    }
    private func image(_ input: Data, width: Int, channels: Int, bits: Int,
                       planar: Bool = false, littleEndian: Bool = true,
                       metadata: SwiftJXL.ImageMetadata = .empty) throws -> Image {
        let height = width == 64 ? 64 : 9, storageBits = bits <= 8 ? 8 : 16
        let step = storageBits / 8
        let roles: [ComponentRole] = (channels <= 2 ? [.grey] : [.red, .green, .blue]) + (channels % 2 == 0 ? [.alpha] : [])
        let stride = planar ? step : channels * step, row = width * stride + 8, planeBytes = row * height + 12
        let planes = try (0..<(planar ? channels : 1)).map { c in
            try PlaneDescriptor(width: width, height: height, components: planar ? [c] : Array(0..<channels),
                offset: 16 + c * planeBytes, sampleStride: step, pixelStride: stride, rowBytes: row,
                byteCount: 16 + (c + 1) * planeBytes)
        }
        let d = try ImageDescriptor(width: width, height: height, storageBits: storageBits, meaningfulBits: bits,
            byteOrder: littleEndian ? .littleEndian : .bigEndian, components: roles,
            colour: channels <= 2 ? .greyscale : .rgb, alpha: channels % 2 == 0 ? .straight : .absent, planes: planes)
        let image = try ImageDestination.allocate(descriptor: d).write { bytes in
            for y in 0..<height { for x in 0..<width { for c in 0..<channels {
                let from = ((y * width + x) * channels + c) * step
                let to = 16 + (planar ? c * planeBytes : c * step) + y * row + x * stride
                bytes[to] = input[from + (littleEndian ? 0 : step - 1)]
                if step == 2 { bytes[to + 1] = input[from + (littleEndian ? 1 : 0)] }
            } } }
        }
        return try Image(descriptor: d, storage: image.storage, metadata: metadata)
    }
    @Test(arguments: [17, 64, 257], [1, 2, 3, 4])
    func publicEncodingMatchesIndependentlyAcceptedStreams(_ width: Int, _ channels: Int) async throws {
        if width == 257 && channels % 2 == 0 { return } // explicit profile rejection is tested separately
        for bits in [8, 16] {
            let name = "enc-\(width)-\(channels)-\(bits)"
            let input = try width == 257 ? fixture(name, suffix: "input", directory: "VarDCT/Encoder")
                : fixture("pred-\(width)-\(channels)-\(bits)", suffix: "input")
            let source = try image(input, width: width, channels: channels, bits: bits,
                planar: channels % 2 == 0, littleEndian: bits == 8)
            let sourceBytes = try source.storage.withUnsafeBytes { Data($0) }
            for prepared in [false, true] {
                let controls = try VarDCTEncodingOptions(gaborish: prepared, adaptiveQuantisation: prepared, dcSmoothing: prepared)
                let encoder = try Encoder(configuration: .init(mode: .lossy, codecOptions: .init(varDCT: controls)))
                let audit = ScalarStorageAudit()
                let encoded = try await ScalarStorageAudit.$current.withValue(audit) {
                    try await encoder.encode(source, options: .init(copyPolicy: .requireSharedStorage))
                }
                #expect(encoded.encoding.mode == .lossy && encoded.report.fidelity == .lossy)
                #expect(encoded.report.copyEvents.isEmpty && audit.snapshot.finalPixelAllocations == 0)
                let expected = try fixture(name, suffix: "jxl", directory: prepared ? "VarDCT/EncoderPrepared" : "VarDCT/Encoder")
                #expect(encoded.data == expected)
                #expect(try source.storage.withUnsafeBytes { Data($0) } == sourceBytes)
                #expect(try await Decoder().decode(encoded.data).report.fidelity == .lossy)
            }
        }
    }
    @Test(arguments: Array(8...16), [1, 2, 3, 4])
    func allIntegerPrecisionsPreserveMeaningAndAlpha(_ bits: Int, _ channels: Int) async throws {
        let maximum = (1 << bits) - 1, step = bits <= 8 ? 1 : 2
        var input = Data(count: 17 * 9 * channels * step)
        for i in 0..<(17 * 9 * channels) {
            let value = (i % 19 == 0) ? maximum : (i * 127 + i * i * 13) % (maximum + 1)
            input[i * step] = UInt8(truncatingIfNeeded: value)
            if step == 2 { input[i * step + 1] = UInt8(value >> 8) }
        }
        let padded = try image(input, width: 17, channels: channels, bits: bits,
                               planar: true, littleEndian: false)
        let interleaved = try image(input, width: 17, channels: channels, bits: bits)
        let encoder = try Encoder(configuration: .init(mode: .lossy))
        let encoded = try await encoder.encode(padded)
        #expect(try await encoder.encode(interleaved).data == encoded.data)
        let name = "precision-\(bits)-\(channels)"
        #expect(try encoded.data == fixture(name, suffix: "jxl", directory: "VarDCT/EncoderPrecision"))
        let reference = try fixture(name, suffix: "scalar", directory: "VarDCT/EncoderPrecision")
        #expect(reference.count == 17 * 9 * channels * 4)
        var squaredError = 0.0, colourCount = 0, peakError = 0
        let decoder = try Decoder()
        let info = try decoder.inspect(encoded.data)
        #expect(info.descriptor.meaningfulBits == bits)
        let decoded = try await decoder.decode(encoded.data)
        #expect(decoded.image.descriptor.meaningfulBits == bits)
        #expect(decoded.report.fidelity == .lossy && decoded.report.copyEvents.isEmpty)
        var samples = Data()
        for y in 0..<9 { for x in 0..<17 { for c in 0..<channels {
            let actual = try decoded.image.storage.withUnsafeBytes { bytes in
                let offset = ((y * 17 + x) * channels + c) * 2
                return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            }
            #expect(Int(actual) <= maximum)
            let sampleIndex = (y * 17 + x) * channels + c
            let raw = reference.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: sampleIndex * 4, as: UInt32.self) }
            let expectedReference = Int((min(1, max(0, Double(Float(bitPattern: UInt32(littleEndian: raw))))) * Double(maximum)).rounded())
            if channels % 2 != 0 || c != channels - 1 {
                let difference = abs(Int(actual) - expectedReference)
                peakError = max(peakError, difference); squaredError += Double(difference * difference); colourCount += 1
            } else { #expect(Int(actual) == expectedReference) }
            samples.append(UInt8(truncatingIfNeeded: actual)); samples.append(UInt8(actual >> 8))
            if channels % 2 == 0 && c == channels - 1 {
                let i = ((y * 17 + x) * channels + c) * step
                let expected = Int(input[i]) | (step == 2 ? Int(input[i + 1]) << 8 : 0)
                #expect(Int(actual) == expected)
            }
        } } }
        #expect(peakError <= 2 && sqrt(squaredError / Double(colourCount)) <= 0.5)
        // Optional qualification export; ordinary unit tests remain offline.
        if let path = ProcessInfo.processInfo.environment["SWIFTJXL_PUBLIC_ENCODER_OUTPUT"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "precision-\(bits)-\(channels)"
            try encoded.data.write(to: directory.appendingPathComponent(name + ".jxl"))
            try input.write(to: directory.appendingPathComponent(name + ".input"))
            try samples.write(to: directory.appendingPathComponent(name + ".decoded"))
        }
    }
    @Test func defaultsAreExplicitAndInvalidOptionsReject() throws {
        let lossy = try EncoderConfiguration(mode: .lossy)
        #expect(lossy.mode == .lossy && EncoderConfiguration.default.mode == .lossless)
        let defaults = VarDCTEncodingOptions.default
        #expect(defaults.distance == 1 && defaults.gaborish && defaults.adaptiveQuantisation && defaults.dcSmoothing)
        for value: Float in [0, -1, .nan, .infinity] {
            #expect(throws: CodecError.self) { _ = try VarDCTEncodingOptions(distance: value) }
        }
        #expect(throws: CodecError.self) { _ = try EncoderConfiguration(mode: .lossless, codecOptions: .init(varDCT: .default)) }
        #expect(throws: CodecError.self) { _ = try Decoder(configuration: .init(codecOptions: .init(varDCT: .default))) }
    }
    @Test func distanceMetadataLimitsAndCancellation() async throws {
        let input = try fixture("pred-17-1-8", suffix: "input")
        let source = try image(input, width: 17, channels: 1, bits: 8)
        let encoder = try Encoder(configuration: .init(mode: .lossy))
        let ordinary = try await encoder.encode(source)
        let controls = try VarDCTEncodingOptions(distance: 2)
        let changed = try await Encoder(configuration: .init(mode: .lossy, codecOptions: .init(varDCT: controls))).encode(source)
        #expect(ordinary.data != changed.data && changed.report.fidelity == .lossy)
        let bt709 = SwiftJXL.ImageMetadata(entries: ["jpegXL.transferFunction": Data([1])], requiredKeys: ["jpegXL.transferFunction"])
        do {
            _ = try await encoder.encode(image(input, width: 17, channels: 1, bits: 8, metadata: bt709))
            Issue.record("Unsupported transfer was silently changed")
        } catch let error as CodecError { #expect(error.category == .unsupportedFeature) }
        do {
            _ = try await encoder.encode(source, options: .init(resourceLimits: .init(maximumWorkspaceBytes: 1)))
            Issue.record("Workspace limit ignored")
        } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
        let task = Task {
            try await encoder.encode(source, options: .init(progress: { update in
                if update.phase == .completed { withUnsafeCurrentTask { $0?.cancel() } }
            }))
        }
        do { _ = try await task.value; Issue.record("Cancelled encoded result returned") }
        catch is CancellationError {}
    }
    @Test func groupedAlphaRejects() async throws {
        let input = Data(repeating: 0, count: 257 * 9 * 2)
        let source = try image(input, width: 257, channels: 2, bits: 8)
        do {
            _ = try await Encoder(configuration: .init(mode: .lossy)).encode(source)
            Issue.record("Unimplemented grouped alpha was encoded")
        } catch let error as CodecError { #expect(error.category == .unsupportedFeature) }
    }
}
