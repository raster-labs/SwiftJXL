// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import SwiftJXL

// Avoid concurrent oracle processes and instrumented large-frame oversubscription.
@Suite(.serialized)
struct NativeTranscoderPublicTests {
    static let fixtures = ["gray", "444", "422", "420", "440", "progressive", "restart", "metadata-tail",
        "fill-marker", "progressive-edge", "progressive-restart", "progressive-422", "progressive-440",
        "progressive-dc-refine", "sequential-multiscan", "multigroup-420", "multigroup-progressive-422", "wide-gray", "quant16"]
    private func source(_ name: String) throws -> Data {
        let dir = name.hasPrefix("multigroup") || name == "wide-gray" || name == "quant16" ? "JPEGBridge" : "JPEG"
        return try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "jpg", subdirectory: dir)))
    }
    @Test(arguments: fixtures) func publicRepeatedRoundTripPreservesEveryByte(_ name: String) async throws {
        let original = try source(name), transcoder = try Transcoder()
        var jpeg = original
        for _ in 0..<2 {
            let encoded = try await transcoder.transcode(jpeg, to: .jpegXL)
            #expect(encoded.encoding.format == "jpeg-xl" && encoded.report.fidelity == .originalBitstream)
            #expect(encoded.report.backend == .scalarCPU)
            #expect(encoded.report.copyEvents.contains { $0.bytesMoved > 0 })
            // Drop the submitted owner before reconstruction; only JXL is passed.
            jpeg = Data()
            let restored = try await transcoder.transcode(encoded.data, to: .jpeg)
            #expect(restored.encoding.format == "jpeg" && restored.report.fidelity == .originalBitstream)
            jpeg = restored.data
            #expect(jpeg == original)
        }
    }
    @Test func wholeOperationLimitsAndMetadataPolicyAreEnforced() async throws {
        let jpeg = try source("gray"), transcoder = try Transcoder()
        let encoded = try await transcoder.transcode(jpeg, to: .jpegXL)
        for limits in try [ResourceLimits(maximumDimension: 1), ResourceLimits(maximumPixels: 1),
            ResourceLimits(maximumCompressedBytes: 1), ResourceLimits(maximumDecodedBytes: 1),
            ResourceLimits(maximumMetadataBytes: 1), ResourceLimits(maximumWorkspaceBytes: 1),
            ResourceLimits(maximumMemoryBytes: 1), ResourceLimits(deadlineSeconds: 0.000000001)] {
            for (data, target) in [(jpeg, TranscodeTarget.jpegXL), (encoded.data, .jpeg)] {
                do {
                    _ = try await transcoder.transcode(data, to: target, options: .init(resourceLimits: limits))
                    Issue.record("Expected resource rejection")
                } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
            }
        }
        do {
            _ = try await transcoder.transcode(jpeg, to: .jpegXL, options: .init(metadataPolicy: .discardAncillary))
            Issue.record("Metadata discard must reject")
        } catch let error as CodecError { #expect(error.category == .invalidArgument) }
        do {
            _ = try await transcoder.transcode(jpeg, to: .jpegXL, options: .init(executionPolicy: .required(.accelerated)))
            Issue.record("Unavailable backend must reject")
        } catch let error as CodecError { #expect(error.category == .backendUnavailable) }
        let fallback = try await transcoder.transcode(jpeg, to: .jpegXL, options: .init(executionPolicy: .preferred(.accelerated)))
        #expect(fallback.report.fallbackReason != nil)
    }
    @Test func slicedOwnersConcurrentCallsAndCancellation() async throws {
        let expected = try source("progressive-edge")
        var owner = Data([0, 0, 0]); owner.append(expected)
        let sliced = owner[3...]; owner = Data()
        let transcoder = try Transcoder(), phases = Mutex<[ProgressUpdate.Phase]>([])
        let encoded = try await transcoder.transcode(sliced, to: .jpegXL, options: .init(progress: { update in
            phases.withLock { $0.append(update.phase) }
        }))
        #expect(phases.withLock { $0 } == [.processing, .completed])
        var compressedOwner = Data([0,0,0,0,0]); compressedOwner.append(encoded.data)
        let compressedSlice = compressedOwner[5...]; compressedOwner = Data()
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<4 { group.addTask { try await transcoder.transcode(compressedSlice, to: .jpeg).data } }
            for try await restored in group { #expect(restored == expected) }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transcoder.transcode(encoded.data, to: .jpeg)
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
    }
    @Test func rejectsMissingDuplicateTruncatedAndUnsupportedReconstruction() async throws {
        let jpeg = try source("gray"), transcoder = try Transcoder()
        let encoded = try await transcoder.transcode(jpeg, to: .jpegXL).data
        let jbrdSize = encoded[32..<36].reduce(0) { ($0 << 8) | Int($1) }
        let header = Data(encoded.prefix(32)), bundle = Data(encoded[32..<(32 + jbrdSize)])
        let frame = Data(encoded.dropFirst(32 + jbrdSize))
        let invalid = [header + frame, header + bundle + bundle + frame,
            Data(encoded.dropLast()), header + bundle, header + bundle + frame + frame]
        for data in invalid {
            do { _ = try await transcoder.transcode(data, to: .jpeg); Issue.record("Malformed container accepted") }
            catch let error as CodecError { #expect(error.category == .malformedInput) }
        }
        // A malformed ICC profile must reject rather than invent colour metadata.
        let payload = Data("ICC_PROFILE\0".utf8) + Data([1,1,0,0,0,0])
        var icc = jpeg
        icc.insert(contentsOf: Data([0xff,0xe2,0,UInt8(payload.count + 2)]) + payload, at: 2)
        do { _ = try await transcoder.transcode(icc, to: .jpegXL); Issue.record("Invalid ICC was accepted") }
        catch let error as CodecError { #expect(error.category == .malformedInput) }
    }

    @Test func iccFragmentValidationAndLimits() async throws {
        let profile = try Data(contentsOf: #require(Bundle.module.url(forResource: "srgb", withExtension: "icc", subdirectory: "JPEGBridge")))
        let base = try source("444"), transcoder = try Transcoder()
        func marker(_ part: UInt8, _ count: UInt8, _ body: Data) -> Data {
            let payload = Data("ICC_PROFILE\0".utf8) + Data([part, count]) + body
            let size = payload.count + 2
            return Data([0xff,0xe2,UInt8(size >> 8),UInt8(size & 255)]) + payload
        }
        func jpeg(_ markers: Data) -> Data {
            var bytes = base; bytes.insert(contentsOf: markers, at: 2); return bytes
        }
        let first = marker(1, 2, Data(profile.prefix(200)))
        let second = marker(2, 2, Data(profile.dropFirst(200)))
        // Fragment sequence identifiers control assembly, while exact marker
        // order is preserved in the reconstructed original bitstream.
        let original = jpeg(second + first)
        let exact = try ResourceLimits(maximumICCBytes: profile.count)
        let encoded = try await transcoder.transcode(original, to: .jpegXL, options: .init(resourceLimits: exact))
        #expect(try await transcoder.transcode(encoded.data, to: .jpeg, options: .init(resourceLimits: exact)).data == original)
        let limited = try ResourceLimits(maximumICCBytes: profile.count - 1)
        for (bytes, target) in [(original, TranscodeTarget.jpegXL), (encoded.data, .jpeg)] {
            do {
                _ = try await transcoder.transcode(bytes, to: target, options: .init(resourceLimits: limited))
                Issue.record("ICC limit was not enforced")
            } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
        }
        for markers in [first, first + first, marker(0, 1, profile), marker(2, 1, profile),
                        first + marker(2, 3, Data(profile.dropFirst(200)))] {
            do { _ = try await transcoder.transcode(jpeg(markers), to: .jpegXL); Issue.record("Malformed ICC fragments accepted") }
            catch let error as CodecError { #expect(error.category == .malformedInput) }
        }
    }

    #if os(macOS) || os(Linux)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"] != nil),
          arguments: fixtures + ["exif-xmp", "icc-rgb", "icc-gray", "icc-fragmented"])
    func independentPublicInteroperability(_ name: String) async throws {
        let tools = try #require(ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"])
        let output = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_OUTPUT"]
        let root = output.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("native-public-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if output == nil { try? FileManager.default.removeItem(at: directory) } }
        var original = try source(name == "exif-xmp" || name == "icc-gray" ? "gray" : name.hasPrefix("icc-") ? "444" : name)
        if name.hasPrefix("icc-") {
            let profileName = name == "icc-gray" ? "gray-gamma22" : "srgb"
            let profileURL = try #require(Bundle.module.url(forResource: profileName, withExtension: "icc", subdirectory: "JPEGBridge"))
            let profile = try Data(contentsOf: profileURL)
            let count = name == "icc-fragmented" ? 2 : 1
            var markers = Data()
            for part in 0..<count {
                let start = profile.count * part / count, end = profile.count * (part + 1) / count
                let payload = Data("ICC_PROFILE\0".utf8) + Data([UInt8(part + 1), UInt8(count)]) + profile[start..<end]
                let n = payload.count + 2
                markers.append(contentsOf: [0xff,0xe2,UInt8(n >> 8),UInt8(n & 255)]); markers.append(payload)
            }
            original.insert(contentsOf: markers, at: 2)
        }
        if name == "exif-xmp" {
            let tiff = Data([0x49,0x49,42,0,8,0,0,0,0,0,0,0,0,0])
            let xmp = Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><test>synthetic</test></x:xmpmeta>".utf8)
            var markers = Data()
            for payload in [Data("Exif\0\0".utf8) + tiff, Data("http://ns.adobe.com/xap/1.0/\0".utf8) + xmp] {
                let n = payload.count + 2
                markers.append(contentsOf: [0xff,0xe1,UInt8(n >> 8),UInt8(n & 255)]); markers.append(payload)
            }
            original.insert(contentsOf: markers, at: 2)
        }
        let sourceURL = directory.appendingPathComponent("source.jpg")
        try original.write(to: sourceURL)
        let transcoder = try Transcoder()
        let encoded = try await transcoder.transcode(original, to: .jpegXL)
        let native = directory.appendingPathComponent("native.jxl"), restored = directory.appendingPathComponent("oracle-restored.jpg")
        try encoded.data.write(to: native)
        try run(tools + "/djxl", [native.path, restored.path, "--quiet"], directory: directory)
        #expect(try Data(contentsOf: restored) == original)
        let reference = directory.appendingPathComponent("reference.jxl")
        try run(tools + "/cjxl", [sourceURL.path, reference.path, "--lossless_jpeg=1", "--quiet"], directory: directory)
        let reverse = try await transcoder.transcode(Data(contentsOf: reference), to: .jpeg)
        try reverse.data.write(to: directory.appendingPathComponent("native-restored.jpg"))
        #expect(reverse.data == original)
    }
    private func run(_ executable: String, _ arguments: [String], directory: URL) throws {
        let log = directory.appendingPathComponent(URL(fileURLWithPath: executable).lastPathComponent + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); Issue.record("Reference tool timed out"); throw CancellationError() }
        try #require(process.terminationStatus == 0, "Reference failed: \(log.path)")
    }
    #endif

}
