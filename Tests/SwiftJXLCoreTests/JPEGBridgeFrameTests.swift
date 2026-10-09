// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJXLCore

// Avoid concurrent oracle processes and instrumented large-frame oversubscription.
@Suite(.serialized)
struct JPEGBridgeFrameTests {
    @Test func readerRejectsTruncationTrailingBytesAndEnforcesBudgets() throws {
        let url = try #require(Bundle.module.url(forResource: "gray", withExtension: "jpg", subdirectory: "JPEG"))
        let input = try JPEGCoefficientDecoder.decode(Data(contentsOf: url), policy: JPEGCoefficientPolicy())
        let view = try JPEGBridgeCoefficients(frame: input.frame, coefficients: input.coefficients,
            quantisation: input.quantisation, policy: JPEGBridgePolicy())
        let data = try JPEGBridgeFrameWriter.write(view, policy: JPEGBridgePolicy())
        for count in 0..<data.count {
            #expect(throws: (any Error).self) { try JPEGBridgeFrameReader.read(Data(data.prefix(count)), policy: JPEGBridgePolicy()) }
        }
        #expect(throws: (any Error).self) { try JPEGBridgeFrameReader.read(data + Data([0]), policy: JPEGBridgePolicy()) }
        for policy in try [JPEGBridgePolicy(maximumCoefficientBytes: 1), JPEGBridgePolicy(maximumMemoryBytes: 1),
                           JPEGBridgePolicy(deadline: .now.advanced(by: .seconds(-1)))] {
            #expect(throws: (any Error).self) { try JPEGBridgeFrameReader.read(data, policy: policy) }
        }
        let calls = Mutex(0)
        _ = try JPEGBridgeFrameReader.read(data, policy: JPEGBridgePolicy(checkpoint: { calls.withLock { $0 += 1 } }))
        let total = calls.withLock { $0 }
        for stop in [1, total / 2, total] {
            let counter = Mutex(0)
            let policy = try JPEGBridgePolicy(checkpoint: {
                if counter.withLock({ $0 += 1; return $0 }) == stop { throw CancellationError() }
            })
            #expect(throws: CancellationError.self) { try JPEGBridgeFrameReader.read(data, policy: policy) }
            #expect(counter.withLock { $0 } == stop)
        }
    }

    @Test func readerBoundsMutationsAndOwnsConcurrentResults() async throws {
        let url = try #require(Bundle.module.url(forResource: "progressive-edge", withExtension: "jpg", subdirectory: "JPEG"))
        let input = try JPEGCoefficientDecoder.decode(Data(contentsOf: url), policy: JPEGCoefficientPolicy())
        let view = try JPEGBridgeCoefficients(frame: input.frame, coefficients: input.coefficients,
            quantisation: input.quantisation, policy: JPEGBridgePolicy())
        let data = try JPEGBridgeFrameWriter.write(view, policy: JPEGBridgePolicy())
        for offset in stride(from: 0, to: data.count, by: max(1, data.count / 64)) {
            for mask in [UInt8(1), 128] {
                var changed = data; changed[offset] ^= mask
                do {
                    let result = try JPEGBridgeFrameReader.read(changed, policy: JPEGBridgePolicy(
                        maximumMemoryBytes: 32 * 1024 * 1024, deadline: .now.advanced(by: .seconds(1))))
                    #expect(result.width > 0 && result.width <= 2048)
                    #expect(result.height > 0 && result.height <= 2048)
                    #expect(result.coefficients.count == result.quantisation.count)
                    #expect(result.quantisation.allSatisfy { $0.count == 64 && $0.allSatisfy { (1...65535).contains($0) } })
                } catch { /* Defined rejection is also a valid mutation outcome. */ }
            }
        }
        try await withThrowingTaskGroup(of: [[Int32]].self) { group in
            for _ in 0..<4 {
                group.addTask { try JPEGBridgeFrameReader.read(data, policy: JPEGBridgePolicy()).coefficients }
            }
            for try await coefficients in group { #expect(coefficients == input.coefficients) }
        }
    }

    @Test func largerEntropyContextCountRequiresBoundedOptIn() throws {
        var writer = BitWriter()
        let header = EntropySectionHeader(lz77: .disabled, contextMap: .trivial(numContexts: 7425),
            usePrefixCode: true, logAlphaSize: 15, uintConfigs: [HybridUintConfig(splitExponent: 4, msbInToken: 0, lsbInToken: 0)])
        try header.write(to: &writer, numContexts: 7425)
        let data = writer.finishToData()
        var ordinary = BitReader(data)
        #expect(throws: (any Error).self) { try EntropySectionHeader.read(from: &ordinary, numContexts: 7425) }
        var admitted = BitReader(data)
        #expect(try EntropySectionHeader.read(from: &admitted, numContexts: 7425, maximumContexts: 7425).contextMap.map.count == 7425)
        var excessive = BitReader(data)
        #expect(throws: (any Error).self) { try EntropySectionHeader.read(from: &excessive, numContexts: 7425, maximumContexts: Int.max) }
    }

    @Test func frameWriterAdmissionOutputBoundAndCancellation() throws {
        let url = try #require(Bundle.module.url(forResource: "gray", withExtension: "jpg", subdirectory: "JPEG"))
        let input = try JPEGCoefficientDecoder.decode(Data(contentsOf: url), policy: JPEGCoefficientPolicy())
        let view = try JPEGBridgeCoefficients(frame: input.frame, coefficients: input.coefficients,
            quantisation: input.quantisation, policy: JPEGBridgePolicy())
        let result = try JPEGBridgeFrameWriter.write(view, policy: JPEGBridgePolicy())
        #expect(try JPEGBridgeFrameWriter.write(view, maximumOutputBytes: result.count, policy: JPEGBridgePolicy()) == result)
        for limit in [0, 1, result.count - 1] {
            #expect(throws: (any Error).self) { try JPEGBridgeFrameWriter.write(view, maximumOutputBytes: limit, policy: JPEGBridgePolicy()) }
        }
        for policy in try [JPEGBridgePolicy(maximumCoefficientBytes: 1), JPEGBridgePolicy(maximumMemoryBytes: 1),
                           JPEGBridgePolicy(deadline: .now.advanced(by: .seconds(-1)))] {
            #expect(throws: (any Error).self) { try JPEGBridgeFrameWriter.write(view, policy: policy) }
        }
        let calls = Mutex(0)
        let counting = try JPEGBridgePolicy(checkpoint: { calls.withLock { $0 += 1 } })
        _ = try JPEGBridgeFrameWriter.write(view, policy: counting)
        let total = calls.withLock { $0 }
        for stop in [1, total / 2, total] {
            let counter = Mutex(0)
            let policy = try JPEGBridgePolicy(checkpoint: {
                if counter.withLock({ $0 += 1; return $0 }) == stop { throw CancellationError() }
            })
            #expect(throws: CancellationError.self) { try JPEGBridgeFrameWriter.write(view, policy: policy) }
            #expect(counter.withLock { $0 } == stop)
        }
    }

    @Test func largerDCGroupProfileIsExplicitlyUnsupported() throws {
        // A valid SOF1 geometry owner; coefficients are synthetic zeros.
        let header = Data([8, 0, 1, 8, 1, 1, 1, 0x11, 0]) // 2049 × 1
        let frame = try JPEGFrameLayout(data: header,
            segment: JPEGSegment(markerByte: 0xc1, markerRange: 0..<0, payloadRange: 0..<header.count,
                                 entropyRange: header.count..<header.count), maximumCoefficientBytes: 1024 * 1024)
        let view = try JPEGBridgeCoefficients(frame: frame,
            coefficients: [[Int32](repeating: 0, count: frame.coefficientCount)],
            quantisation: [[UInt16](repeating: 1, count: 64)], policy: JPEGBridgePolicy())
        #expect(throws: JPEGEntropyError.unsupported) { try JPEGBridgeFrameWriter.write(view, policy: JPEGBridgePolicy()) }
    }

    #if os(macOS) || os(Linux)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"] != nil),
          arguments: ["gray", "444", "422", "420", "440", "progressive", "restart", "metadata-tail",
                      "fill-marker", "progressive-edge", "progressive-restart", "progressive-422",
                      "progressive-440", "progressive-dc-refine", "sequential-multiscan",
                      "multigroup-420", "multigroup-progressive-422", "wide-gray", "quant16"])
    func nativeFrameAndMetadataRestoreWithIndependentDecoder(_ name: String) throws {
        let directoryName = name.hasPrefix("multigroup") || name == "wide-gray" || name == "quant16" ? "JPEGBridge" : "JPEG"
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jpg", subdirectory: directoryName))
        let source = try Data(contentsOf: url)
        let decoded = try JPEGCoefficientDecoder.decode(source, policy: JPEGCoefficientPolicy())
        let policy = try JPEGBridgePolicy()
        let view = try JPEGBridgeCoefficients(frame: decoded.frame, coefficients: decoded.coefficients,
            quantisation: decoded.quantisation, policy: policy)
        let codestream = try JPEGBridgeFrameWriter.write(view, policy: policy)
        let metadata = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy())
        let bundle = metadata.bundle
        let nativeFrame = try JPEGBridgeFrameReader.read(codestream, policy: JPEGBridgePolicy())
        #expect(nativeFrame.coefficients == decoded.coefficients)
        #expect(nativeFrame.quantisation == decoded.quantisation.map { $0.map(Int32.init) })
        #expect(try JPEGReconstructionWriter.write(coefficients: nativeFrame.coefficients,
            metadata: nativeFrame.resolve(metadata.box), policy: JPEGReconstructionPolicy()) == source)
        var container = Data([0,0,0,12,0x4a,0x58,0x4c,0x20,0x0d,0x0a,0x87,0x0a,
                              0,0,0,20,0x66,0x74,0x79,0x70,0x6a,0x78,0x6c,0x20,0,0,0,0,0x6a,0x78,0x6c,0x20])
        for (type, bytes) in [("jbrd", bundle), ("jxlc", codestream)] {
            let size = UInt32(bytes.count + 8)
            container.append(contentsOf: [UInt8(truncatingIfNeeded: size >> 24), UInt8(truncatingIfNeeded: size >> 16),
                UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)])
            container.append(Data(type.utf8)); container.append(bytes)
        }
        let tools = try #require(ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"])
        let output = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_OUTPUT"]
        let root = output.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("native-jpeg-frame-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if output == nil { try? FileManager.default.removeItem(at: directory) } }
        let encoded = directory.appendingPathComponent("native.jxl"), restored = directory.appendingPathComponent("restored.jpg")
        try container.write(to: encoded); try source.write(to: directory.appendingPathComponent("source.jpg"))
        let log = directory.appendingPathComponent("djxl.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: tools + "/djxl")
        process.arguments = [encoded.path, restored.path, "--quiet"]
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); Issue.record("djxl timed out"); throw CancellationError() }
        try #require(process.terminationStatus == 0, "Oracle failed: \(log.path)")
        #expect(try Data(contentsOf: restored) == source)

        // Independently encoded entropy trees, ANS tables, coefficient orders
        // and colour correlations exercise the native reverse path as well.
        let reference = directory.appendingPathComponent("reference.jxl")
        let encoder = Process(); encoder.executableURL = URL(fileURLWithPath: tools + "/cjxl")
        encoder.arguments = [directory.appendingPathComponent("source.jpg").path, reference.path,
                             "--lossless_jpeg=1", "--quiet"]
        encoder.standardOutput = handle; encoder.standardError = handle
        try encoder.run()
        let encoderDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        while encoder.isRunning && ContinuousClock.now < encoderDeadline { Thread.sleep(forTimeInterval: 0.01) }
        if encoder.isRunning { encoder.terminate(); Issue.record("cjxl timed out"); throw CancellationError() }
        try #require(encoder.terminationStatus == 0, "Oracle encoder failed: \(log.path)")
        let referenceData = try Data(contentsOf: reference)
        guard case .iso(let boxes) = try parseJXLContainer(referenceData) else {
            Issue.record("Independent JPEG transcode needs a reconstruction container"); return
        }
        let jbrd = try #require(boxes.first { $0.type == "jbrd" })
        let referenceMetadata = try JBRDBoxReader.readResolved(referenceData.subdata(in: jbrd.payloadRange), policy: JBRDPolicy())
        let referenceFrame = try JPEGBridgeFrameReader.read(extractCodestream(from: boxes, in: referenceData), policy: JPEGBridgePolicy())
        let nativeRestored = try JPEGReconstructionWriter.write(coefficients: referenceFrame.coefficients,
            metadata: referenceFrame.resolve(referenceMetadata), policy: JPEGReconstructionPolicy())
        try nativeRestored.write(to: directory.appendingPathComponent("native-restored.jpg"))
        #expect(nativeRestored == source)
    }
    #endif
}
