// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJXLCore

private let metadataCorpus = ["gray", "444", "422", "420", "440", "progressive", "restart",
    "metadata-tail", "fill-marker", "progressive-edge", "progressive-restart", "progressive-422",
    "progressive-440", "progressive-dc-refine", "sequential-multiscan", "sequential-extra-zero",
    "progressive-split", "progressive-grouped", "progressive-restart-split", "progressive-band-zero",
    "zero-padding", "quant-slot-three", "long-fill"]

struct JPEGReconstructionMetadataTests {
    private func source(_ name: String) throws -> Data {
        let synthetic = ["zero-padding", "quant-slot-three", "long-fill", "redefined-quant"].contains(name)
        let stem = synthetic ? "gray" : name
        let directory = metadataCorpus.firstIndex(of: stem).map { $0 < 15 ? "JPEG" : "JPEGEvents" } ?? "JPEG"
        let url = try #require(Bundle.module.url(forResource: stem, withExtension: "jpg", subdirectory: directory))
        var data = try Data(contentsOf: url)
        if name == "zero-padding" {
            let decoded = try JPEGCoefficientDecoder.decode(data, policy: JPEGCoefficientPolicy())
            let pad = try #require(decoded.padding.last)
            try #require(pad.bitCount > 0 && data[pad.offset - 1] != 0)
            data[pad.offset - 1] &= 0xfe
        } else if name == "quant-slot-three" {
            var reader = try JPEGSegmentReader(data)
            while let segment = try reader.next() {
                if segment.markerByte == 0xdb { data[segment.payloadRange.lowerBound] = 3 }
                if segment.markerByte == 0xc0 { data[segment.payloadRange.lowerBound + 8] = 3 }
            }
        } else if name == "redefined-quant" {
            var reader = try JPEGSegmentReader(data)
            var duplicate: Data?, scanStart: Int?
            while let segment = try reader.next() {
                if segment.markerByte == 0xdb {
                    duplicate = Data(data[segment.markerRange.lowerBound..<segment.payloadRange.upperBound])
                }
                if segment.markerByte == 0xda { scanStart = segment.markerRange.lowerBound; break }
            }
            var table = try #require(duplicate)
            table[5] = table[5] == 255 ? 254 : table[5] + 1
            data.insert(contentsOf: table, at: try #require(scanStart))
        } else if name == "long-fill" {
            data.insert(contentsOf: repeatElement(UInt8(0xff), count: 65536), at: data.count - 2)
            data.append(contentsOf: [0, 1, 0xff, 0xd9, 2])
        }
        return data
    }

    @Test(arguments: metadataCorpus)
    func metadataIsSelfContainedAndRetainsSourceRecords(_ name: String) throws {
        let data = try source(name)
        let decoded = try JPEGCoefficientDecoder.decode(data, policy: JPEGCoefficientPolicy())
        let encoded = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy())
        let resolved = try JBRDBoxReader.readResolved(encoded.bundle, policy: JBRDPolicy())
        #expect(resolved.markerOrder == encoded.box.markerOrder)
        #expect(resolved.appData == encoded.box.appData)
        #expect(resolved.comData == encoded.box.comData)
        #expect(resolved.interMarkerData == encoded.box.interMarkerData)
        #expect(resolved.tailData == encoded.box.tailData)
        #expect(resolved.paddingBits == encoded.box.paddingBits)
        #expect(resolved.scanInfo.map(\.resetPoints) == decoded.scans.map(\.resetPoints))
        #expect(resolved.scanInfo.map(\.extraZeroRuns) == decoded.scans.map(\.extraZeroRuns))
        for ci in decoded.frame.components.indices {
            let quant = encoded.box.quant[Int(encoded.box.components[ci].quantIdx)]
            #expect(quant.values == decoded.quantisation[ci].map(Int32.init))
            #expect(quant.index == UInt32(decoded.frame.components[ci].quantisationTable))
        }
        if name == "zero-padding" { #expect(resolved.hasZeroPaddingBit && resolved.paddingBits.contains(0)) }
        if name == "long-fill" { #expect(resolved.interMarkerData.map(\.count) == [65535, 1]) }
    }

    @Test(arguments: metadataCorpus)
    func nativeWriterRestoresOriginalWithoutSourceParameter(_ name: String) throws {
        let original = try source(name)
        let decoded = try JPEGCoefficientDecoder.decode(original, policy: JPEGCoefficientPolicy())
        let metadata = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy()).box
        let restored = try JPEGReconstructionWriter.write(coefficients: decoded.coefficients, metadata: metadata,
                                                         policy: JPEGReconstructionPolicy())
        #expect(restored == original)
    }

    @Test(arguments: Array(metadataCorpus.prefix(20)))
    func nativeWriterAcceptsIndependentMetadata(_ name: String) throws {
        let decoded = try JPEGCoefficientDecoder.decode(source(name), policy: JPEGCoefficientPolicy())
        let native = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy()).box
        let directory = metadataCorpus.firstIndex(of: name).map { $0 < 15 ? "JBRD" : "JPEGEvents" } ?? "JBRD"
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jbrd", subdirectory: directory))
        var metadata = try JBRDBoxReader.readResolved(Data(contentsOf: url), policy: JBRDPolicy())
        metadata.width = native.width; metadata.height = native.height
        try #require(metadata.quant.count == native.quant.count && metadata.components.count == native.components.count)
        for i in metadata.quant.indices { metadata.quant[i].values = native.quant[i].values }
        for i in metadata.components.indices {
            metadata.components[i].hSampFactor = native.components[i].hSampFactor
            metadata.components[i].vSampFactor = native.components[i].vSampFactor
            metadata.components[i].widthInBlocks = native.components[i].widthInBlocks
            metadata.components[i].heightInBlocks = native.components[i].heightInBlocks
        }
        #expect(try JPEGReconstructionWriter.write(coefficients: decoded.coefficients, metadata: metadata,
                                                  policy: JPEGReconstructionPolicy()) == decoded.source)
    }

    @Test func nativeWriterLimitsAndCancellationAtEveryPhase() throws {
        let original = try source("progressive")
        let decoded = try JPEGCoefficientDecoder.decode(original, policy: JPEGCoefficientPolicy())
        let metadata = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy()).box
        #expect(try JPEGReconstructionWriter.write(coefficients: decoded.coefficients, metadata: metadata,
            policy: JPEGReconstructionPolicy(maximumOutputBytes: original.count)) == original)
        for policy in try [JPEGReconstructionPolicy(maximumOutputBytes: original.count - 1),
                           JPEGReconstructionPolicy(maximumCoefficientBytes: 1),
                           JPEGReconstructionPolicy(maximumMemoryBytes: 1),
                           JPEGReconstructionPolicy(maximumBufferedRefinementBits: 1),
                           JPEGReconstructionPolicy(deadline: .now.advanced(by: .seconds(-1)))] {
            #expect(throws: (any Error).self) {
                try JPEGReconstructionWriter.write(coefficients: decoded.coefficients, metadata: metadata, policy: policy)
            }
        }
        let count = Mutex(0)
        _ = try JPEGReconstructionWriter.write(coefficients: decoded.coefficients, metadata: metadata,
            policy: JPEGReconstructionPolicy(checkpoint: { count.withLock { $0 += 1 } }))
        let total = count.withLock { $0 }
        for stop in [1, total / 4, total / 2, total - 1, total] {
            let calls = Mutex(0)
            #expect(throws: CancellationError.self) {
                try JPEGReconstructionWriter.write(coefficients: decoded.coefficients, metadata: metadata,
                    policy: JPEGReconstructionPolicy(checkpoint: {
                        if calls.withLock({ $0 += 1; return $0 }) == stop { throw CancellationError() }
                    }))
            }
            #expect(calls.withLock { $0 } == stop)
        }
    }

    @Test func nativeWriterRejectsInconsistentOwnersAndMetadata() throws {
        let decoded = try JPEGCoefficientDecoder.decode(source("gray"), policy: JPEGCoefficientPolicy())
        let original = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy()).box
        var mutations: [JBRDBox] = []
        var box = original; box.width = Int.max; mutations.append(box)
        box = original; box.quant[0].values[0] = Int32.min; mutations.append(box)
        box = original; box.components[0].widthInBlocks += 1; mutations.append(box)
        box = original; box.scanInfo[0].components[0].compIdx = UInt32.max; mutations.append(box)
        box = original; box.scanInfo[0].resetPoints = [10000]; mutations.append(box)
        box = original; box.scanInfo[0].extraZeroRuns = [JBRDExtraZeroRun(blockIdx: 10000, numExtraZeroRuns: 1)]; mutations.append(box)
        box = original; box.huffmanCode[0].values.removeLast(); mutations.append(box)
        box = original; box.hasZeroPaddingBit = true; box.paddingBits = []; mutations.append(box)
        box = original; box.hasZeroPaddingBit = true; box.paddingBits = [UInt8](repeating: 1, count: 64); mutations.append(box)
        box = original; box.markerOrder.swapAt(0, box.markerOrder.firstIndex(of: 0xda) ?? 0); mutations.append(box)
        for changed in mutations {
            #expect(throws: (any Error).self) {
                try JPEGReconstructionWriter.write(coefficients: decoded.coefficients, metadata: changed,
                                                  policy: JPEGReconstructionPolicy())
            }
        }
        for changed in [[], [Array(decoded.coefficients[0].dropLast())], [[Int32](repeating: Int32.min, count: decoded.coefficients[0].count)]] {
            #expect(throws: (any Error).self) {
                try JPEGReconstructionWriter.write(coefficients: changed, metadata: original, policy: JPEGReconstructionPolicy())
            }
        }
    }

    @Test func nativeWriterCoefficientMutationsEitherRejectOrRoundtripExactly() throws {
        let decoded = try JPEGCoefficientDecoder.decode(source("gray"), policy: JPEGCoefficientPolicy())
        let metadata = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy()).box
        var accepted = 0
        for offset in stride(from: 0, to: decoded.coefficients[0].count, by: 19) {
            for value: Int32 in [Int32.min, -1023, 0, 1023, Int32.max] {
                var changed = decoded.coefficients; changed[0][offset] = value
                let bytes: Data
                do {
                    bytes = try JPEGReconstructionWriter.write(coefficients: changed, metadata: metadata,
                        policy: JPEGReconstructionPolicy(maximumOutputBytes: 1024 * 1024))
                } catch { continue } // The original Huffman tables need not represent every mutation.
                let restored = try JPEGCoefficientDecoder.decode(bytes, policy: JPEGCoefficientPolicy())
                #expect(restored.coefficients == changed)
                accepted += 1
            }
        }
        #expect(accepted > 10)
    }

    @Test func nativeWriterCrossesMaximumProgressiveEOBRun() throws {
        let url = try #require(Bundle.module.url(forResource: "large-eob", withExtension: "jpg", subdirectory: "JPEGEvents"))
        let source = try Data(contentsOf: url)
        let decoded = try JPEGCoefficientDecoder.decode(source,
            policy: JPEGCoefficientPolicy(deadline: .now.advanced(by: .seconds(60))))
        #expect(decoded.coefficients.count == 1 && decoded.coefficients[0].count == 32768 * 64)
        #expect(decoded.coefficients[0].allSatisfy { $0 == 0 })
        let native = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy(deadline: .now.advanced(by: .seconds(60)))).box
        let bundle = try #require(Bundle.module.url(forResource: "large-eob", withExtension: "jbrd", subdirectory: "JPEGEvents"))
        var independent = try JBRDBoxReader.readResolved(Data(contentsOf: bundle), policy: JBRDPolicy())
        #expect(independent.scanInfo.map(\.resetPoints) == native.scanInfo.map(\.resetPoints))
        #expect(independent.scanInfo.contains { $0.resetPoints.contains(32767) })
        independent.width = native.width; independent.height = native.height
        for i in independent.quant.indices { independent.quant[i].values = native.quant[i].values }
        for i in independent.components.indices {
            independent.components[i].hSampFactor = native.components[i].hSampFactor
            independent.components[i].vSampFactor = native.components[i].vSampFactor
            independent.components[i].widthInBlocks = native.components[i].widthInBlocks
            independent.components[i].heightInBlocks = native.components[i].heightInBlocks
        }
        #expect(try JPEGReconstructionWriter.write(coefficients: decoded.coefficients, metadata: independent,
            policy: JPEGReconstructionPolicy(deadline: .now.advanced(by: .seconds(60)))) == source)
    }

    @Test func nativeWriterConcurrentOwnersAndTaskCancellation() async throws {
        let decoded = try JPEGCoefficientDecoder.decode(source("progressive-restart"), policy: JPEGCoefficientPolicy())
        let metadata = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy()).box
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try JPEGReconstructionWriter.write(coefficients: decoded.coefficients, metadata: metadata,
                                                       policy: JPEGReconstructionPolicy())
                }
            }
            for try await bytes in group { #expect(bytes == decoded.source) }
        }
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) {
                try JPEGReconstructionWriter.write(coefficients: decoded.coefficients, metadata: metadata,
                                                   policy: JPEGReconstructionPolicy())
            }
        }.value
    }

    @Test func resourceLimitsAndMidOperationCancellation() throws {
        let decoded = try JPEGCoefficientDecoder.decode(source("progressive-split"), policy: JPEGCoefficientPolicy())
        for policy in try [JBRDPolicy(maximumInputBytes: 1), JBRDPolicy(maximumMemoryBytes: 1),
                           JBRDPolicy(maximumMarkers: 1), JBRDPolicy(maximumEvents: 1),
                           JBRDPolicy(maximumPaddingBits: 1), JBRDPolicy(deadline: .now.advanced(by: .seconds(-1)))] {
            #expect(throws: (any Error).self) { try JPEGReconstructionMetadata.encode(decoded, policy: policy) }
        }
        let payload = try JPEGCoefficientDecoder.decode(source("metadata-tail"), policy: JPEGCoefficientPolicy())
        #expect(throws: JBRDError.self) {
            try JPEGReconstructionMetadata.encode(payload, policy: JBRDPolicy(maximumPayloadBytes: 1))
        }
        let counted = Mutex(0)
        _ = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy(checkpoint: {
            counted.withLock { $0 += 1 }
        }))
        // The header writer admits a conservative upper bound. Use a payload
        // larger than that bound to test the final compressed-size boundary.
        let large = try JPEGCoefficientDecoder.decode(source("long-fill"), policy: JPEGCoefficientPolicy())
        let full = try JPEGReconstructionMetadata.encode(large, policy: JBRDPolicy()).bundle
        #expect(try JPEGReconstructionMetadata.encode(large,
            policy: JBRDPolicy(maximumInputBytes: full.count)).bundle == full)
        #expect(throws: (any Error).self) {
            try JPEGReconstructionMetadata.encode(large, policy: JBRDPolicy(maximumInputBytes: full.count - 1))
        }
        let total = counted.withLock { $0 }
        for stop in [1, 30, total / 2, total - 1, total] {
            let calls = Mutex(0)
            let policy = try JBRDPolicy(checkpoint: {
                if calls.withLock({ $0 += 1; return $0 }) == stop { throw CancellationError() }
            })
            #expect(throws: CancellationError.self) { try JPEGReconstructionMetadata.encode(decoded, policy: policy) }
            #expect(calls.withLock { $0 } == stop)
        }
    }

    @Test func supersededFirstQuantisationTableIsUnsupported() throws {
        let original = try JPEGCoefficientDecoder.decode(source("gray"), policy: JPEGCoefficientPolicy())
        let decoded = try JPEGCoefficientDecoder.decode(source("redefined-quant"), policy: JPEGCoefficientPolicy())
        #expect(decoded.coefficients == original.coefficients)
        #expect(decoded.quantisation != original.quantisation)
        #expect(throws: JPEGEntropyError.unsupported) {
            try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy())
        }
    }

    @Test func unrepresentableRestartMetadataIsRejected() throws {
        let data = try source("restart")
        var reader = try JPEGSegmentReader(data)
        var dri: Data?, scanStart: Int?
        while let segment = try reader.next() {
            if segment.markerByte == 0xdd {
                dri = Data(data[segment.markerRange.lowerBound..<segment.payloadRange.upperBound])
            }
            if segment.markerByte == 0xda && scanStart == nil { scanStart = segment.markerRange.lowerBound }
        }
        var repeated = data
        repeated.insert(contentsOf: try #require(dri), at: try #require(scanStart))
        let duplicate = try JPEGCoefficientDecoder.decode(repeated, policy: JPEGCoefficientPolicy())
        #expect(throws: JPEGEntropyError.unsupported) {
            try JPEGReconstructionMetadata.encode(duplicate, policy: JBRDPolicy())
        }
        let decoded = try JPEGCoefficientDecoder.decode(data, policy: JPEGCoefficientPolicy())
        let pad = try #require(decoded.padding.first)
        try #require((0xd0...0xd7).contains(data[pad.offset + 1]))
        var restartFill = data; restartFill.insert(0xff, at: pad.offset)
        let filled = try JPEGCoefficientDecoder.decode(restartFill, policy: JPEGCoefficientPolicy())
        #expect(throws: JPEGEntropyError.unsupported) {
            try JPEGReconstructionMetadata.encode(filled, policy: JBRDPolicy())
        }
    }

    @Test func slicedSourceAndConcurrentMetadataOwners() async throws {
        var owner = Data([9, 8, 7]) + (try source("metadata-tail"))
        let slice = owner.dropFirst(3); owner.removeAll()
        let decoded = try JPEGCoefficientDecoder.decode(slice, policy: JPEGCoefficientPolicy())
        let expected = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy()).bundle
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<4 {
                group.addTask { try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy()).bundle }
            }
            for try await actual in group { #expect(actual == expected) }
        }
    }

    #if os(macOS) || os(Linux)
    /// The frame is independently generated by libjxl; only its jbrd metadata
    /// is replaced. This proves metadata interoperability, not a native frame bridge.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"] != nil), arguments: metadataCorpus)
    func independentDecoderReconstructsEveryOriginalByte(_ name: String) throws {
        let tools = try #require(ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"])
        let output = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_OUTPUT"]
        let root = output.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("jpeg-metadata-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { if output == nil { try? FileManager.default.removeItem(at: dir) } }
        let data = try source(name)
        let original = dir.appendingPathComponent("source.jpg"), reference = dir.appendingPathComponent("reference.jxl")
        let native = dir.appendingPathComponent("native-metadata.jxl"), restored = dir.appendingPathComponent("restored.jpg")
        // libjxl's JPEG reader rejects a single fill run beyond 65535 bytes.
        // Its unchanged coefficient frame can still validate our split records.
        let frameSource = name == "long-fill" ? try source("gray") : data
        try frameSource.write(to: original)
        try data.write(to: dir.appendingPathComponent("expected.jpg"))
        try run(tools + "/cjxl", [original.path, reference.path, "--lossless_jpeg=1", "--quiet"], directory: dir)
        let decoded = try JPEGCoefficientDecoder.decode(data, policy: JPEGCoefficientPolicy())
        let bundle = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy()).bundle
        try bundle.write(to: dir.appendingPathComponent("native.jbrd"))
        let container = try Data(contentsOf: reference)
        var offset = 0, replacements = 0, replaced = Data()
        while offset < container.count {
            try #require(container.count - offset >= 8)
            let length = container[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            let end = length == 0 ? container.count : offset + length
            try #require(length != 1 && end <= container.count && end >= offset + 8)
            if container[(offset + 4)..<(offset + 8)] == Data("jbrd".utf8) {
                let size = UInt32(bundle.count + 8)
                replaced.append(contentsOf: [UInt8(truncatingIfNeeded: size >> 24), UInt8(truncatingIfNeeded: size >> 16),
                    UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)])
                replaced.append(Data("jbrd".utf8)); replaced.append(bundle); replacements += 1
            } else { replaced.append(container[offset..<end]) }
            offset = end
        }
        try #require(replacements == 1)
        try replaced.write(to: native)
        try run(tools + "/djxl", [native.path, restored.path, "--quiet"], directory: dir)
        #expect(try Data(contentsOf: restored) == data)
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
        if process.isRunning { process.terminate(); Issue.record("Oracle timed out: \(executable)"); throw CancellationError() }
        try #require(process.terminationStatus == 0, "Oracle failed; log: \(log.path)")
    }
    #endif
}
