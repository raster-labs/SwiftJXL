// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJXLCore

struct JPEGBridgeFrameTests {
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
        let bundle = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy()).bundle
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
    }
    #endif
}
