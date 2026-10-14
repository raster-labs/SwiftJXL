// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

/// Pairwise additions to the existing effort matrix: every greyscale-alpha
/// precision, intermediate RGB(A) precision, both 512-pixel group edges and
/// one-dimensional tails. Synthetic data belongs to this repository.
struct ModularProfileCase: Sendable {
    let width: Int, height: Int, channels: Int, bits: Int
    static let cases: [Self] = [
        .init(width: 31, height: 17, channels: 2, bits: 8),
        .init(width: 511, height: 7, channels: 2, bits: 9),
        .init(width: 512, height: 7, channels: 2, bits: 10),
        .init(width: 513, height: 7, channels: 2, bits: 11),
        .init(width: 7, height: 511, channels: 2, bits: 12),
        .init(width: 7, height: 512, channels: 2, bits: 13),
        .init(width: 7, height: 513, channels: 2, bits: 14),
        .init(width: 1, height: 513, channels: 2, bits: 15),
        .init(width: 513, height: 1, channels: 2, bits: 16),
        .init(width: 31, height: 17, channels: 3, bits: 9),
        .init(width: 513, height: 7, channels: 3, bits: 11),
        .init(width: 7, height: 513, channels: 3, bits: 13),
        .init(width: 512, height: 7, channels: 3, bits: 15),
        .init(width: 513, height: 7, channels: 4, bits: 10),
        .init(width: 7, height: 513, channels: 4, bits: 11),
        .init(width: 31, height: 17, channels: 4, bits: 14),
        .init(width: 7, height: 512, channels: 4, bits: 15)
    ]

    func pixels() -> [[UInt16]] {
        let maximum = (1 << bits) - 1
        var result = [[UInt16]](repeating: [], count: channels)
        var random: UInt32 = 20261014
        for i in 0..<(width * height) {
            for c in 0..<channels {
                random = random &* 1664525 &+ 1013904223
                let ramp = (i % width) * 71 + (i / width) * 108 + c * 113
                var value = (i % 23 < 11 ? ramp : Int(random >> 8)) & maximum
                if i % 127 == 0 { value = c % 2 == 0 ? maximum : 0 }
                if i % 127 == 1 { value = c % 2 == 0 ? 0 : maximum }
                // Nonzero colour under zero straight alpha must survive too.
                result[c].append(UInt16(value))
            }
        }
        return result
    }

    func budget(workers: Int = 1, workspace: Int = 512 * 1024 * 1024,
                cancellation: ScalarOperationCancellation? = nil) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: width * height * channels * 2,
            maximumWorkspaceBytes: workspace, maximumMemoryBytes: 1024 * 1024 * 1024,
            maximumDecodedBytes: 4 * 1024 * 1024, maximumCompressedBytes: 4 * 1024 * 1024,
            deadline: .now.advanced(by: .seconds(120)), maximumWorkers: workers, cancellation: cancellation)
    }

    func encode(_ pixels: [[UInt16]], effort: Int, budget: ScalarOperationBudget) throws -> Data {
        let limit = try budget.admitModularEncoder(width: width, height: height, channels: channels)
        return try ScalarEncodingWork.$current.withValue(.init(budget: budget, writerByteLimit: limit)) {
            if channels == 2 {
                if bits == 8 {
                    return try SpecModularEncoder.encodeGrayscaleAlpha8(width: width, height: height,
                        gray: pixels[0].map(UInt8.init), alpha: pixels[1].map(UInt8.init), effort: effort)
                }
                return try SpecModularEncoder.encodeGrayscaleAlpha16(width: width, height: height,
                    bitsPerSample: UInt32(bits), gray: pixels[0], alpha: pixels[1], effort: effort)
            }
            if channels == 3 {
                return try SpecModularEncoder.encodeRGB16(width: width, height: height,
                    bitsPerSample: UInt32(bits), r: pixels[0], g: pixels[1], b: pixels[2], effort: effort)
            }
            return try SpecModularEncoder.encodeRGBA16(width: width, height: height,
                bitsPerSample: UInt32(bits), r: pixels[0], g: pixels[1], b: pixels[2], a: pixels[3], effort: effort)
        }
    }
}

struct ModularProfileTests {
    @Test(arguments: Array(ModularProfileCase.cases.indices), [3, 7, 8, 9])
    func precisionAlphaAndGroupEdges(_ index: Int, _ effort: Int) throws {
        let f = ModularProfileCase.cases[index], pixels = f.pixels()
        let serial = try f.encode(pixels, effort: effort, budget: f.budget())
        let parallel = try f.encode(pixels, effort: effort, budget: f.budget(workers: 8))
        #expect(serial == parallel)
        #expect(pixels == f.pixels())
        let decoded = try ModularFrameDecoder.decode(serial, budget: f.budget())
        #expect(decoded.bitsPerSample == f.bits)
        #expect(decoded.alphaAssociated == (f.channels == 3 ? nil : false))
        #expect(decoded.image.channels.map(\.pixels) == pixels.map { $0.map(Int32.init) })
        // Exercise direct output with reversed planes, pixel gaps, guard bytes
        // and a different row stride from the packed source. Compare padding too.
        let stride = 4, row = f.width * stride + 6, planeBytes = row * f.height + 12
        let layouts = try (0..<f.channels).map { c in
            try ModularChannelLayout(width: f.width, height: f.height,
                offset: 8 + (f.channels - 1 - c) * planeBytes,
                rowBytes: row, pixelStride: stride, storageBits: 16, littleEndian: false)
        }
        var actual = [UInt8](repeating: 0xA5, count: f.channels * planeBytes + 16), expected = actual
        for c in 0..<f.channels { for i in 0..<(f.width * f.height) {
            let p = layouts[c].offset + (i / f.width) * row + (i % f.width) * stride
            expected[p] = UInt8(pixels[c][i] >> 8)
            expected[p + 1] = UInt8(truncatingIfNeeded: pixels[c][i])
        } }
        let audit = ScalarStorageAudit()
        try ScalarStorageAudit.$current.withValue(audit) {
            let prepared = try ModularFrameDecoder.prepare(serial, budget: f.budget())
            try actual.withUnsafeMutableBytes { try prepared.decode(into: $0, layouts: layouts) }
        }
        #expect(actual == expected)
        #expect(audit.snapshot.finalPixelAllocations == 0)
        #if os(macOS) || os(Linux)
        if let binary = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"] {
            try oracle(serial, fixture: f, pixels: pixels, effort: effort, binary: binary)
        }
        #endif
    }

    @Test(arguments: [10, 11, 13, 14])
    func eightWorkerEffortNineCannotHideLowerBudgetRefusal(_ index: Int) throws {
        let f = ModularProfileCase.cases[index], pixels = f.pixels()
        let two = try f.budget(workers: 2, workspace: 256 * 1024 * 1024)
        let expected = try f.encode(pixels, effort: 9, budget: two)
        let eight = try f.budget(workers: 8)
        #expect(try f.encode(pixels, effort: 9, budget: eight) == expected)
        #expect(two.reservedWorkspaceBytes <= 256 * 1024 * 1024)
        #expect(eight.reservedWorkspaceBytes > 256 * 1024 * 1024)
        let denied = try f.budget(workers: 8, workspace: 256 * 1024 * 1024)
        do {
            _ = try f.encode(pixels, effort: 9, budget: denied)
            Issue.record("Insufficient eight-worker allowance returned a successful candidate")
        } catch ScalarModularError.resourceLimit {}
    }

    @Test(arguments: [3, 7, 8, 9], [3, 6, 13])
    func concurrentBudgetsAndCancellationAreOperationLocal(_ effort: Int, _ index: Int) async throws {
        let f = ModularProfileCase.cases[index], pixels = f.pixels()
        let referenceBudget = try f.budget(workers: 2)
        let expected = try f.encode(pixels, effort: effort, budget: referenceBudget)
        let bound = referenceBudget.reservedWorkspaceBytes
        // Every operation shares immutable samples but has its own admission and
        // cancellation owner. The failed children must not poison healthy peers.
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for operation in 0..<4 {
                group.addTask {
                    let cancellation = ScalarOperationCancellation()
                    let budget = try f.budget(workers: 2,
                        workspace: operation == 2 ? bound - 1 : bound, cancellation: cancellation)
                    if operation == 3 { cancellation.cancel() }
                    do {
                        let data = try f.encode(pixels, effort: effort, budget: budget)
                        #expect(operation < 2)
                        #expect(data == expected && budget.reservedWorkspaceBytes == bound)
                    } catch is CancellationError { #expect(operation == 3) }
                      catch ScalarModularError.resourceLimit { #expect(operation == 2) }
                    return operation
                }
            }
            var results: [Int] = []
            for try await result in group { results.append(result) }
            return results
        }
        #expect(results.sorted() == [0, 1, 2, 3])
        #expect(pixels == f.pixels())
        #expect(try f.encode(pixels, effort: effort, budget: f.budget(workers: 2)) == expected)
    }

    #if os(macOS) || os(Linux)
    func oracle(_ encoded: Data, fixture f: ModularProfileCase, pixels: [[UInt16]],
                        effort: Int, binary: String) throws {
        let saved = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_OUTPUT"]
        let root = saved.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let name = "profile-\(f.width)x\(f.height)-c\(f.channels)-b\(f.bits)-e\(effort)-\(UUID().uuidString)"
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { if saved == nil { try? FileManager.default.removeItem(at: dir) } }
        let input = dir.appendingPathComponent("native.jxl"), output = dir.appendingPathComponent("oracle.pam")
        try encoded.write(to: input)
        let log = dir.appendingPathComponent("oracle.log")
        try Data().write(to: log)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary + "/djxl")
        process.arguments = [input.path, output.path, "--bits_per_sample=\(f.bits)", "--num_threads=2", "--quiet"]
        process.standardOutput = handle; process.standardError = handle
        try process.run(); process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let data = try Data(contentsOf: output)
        let end = try #require(data.range(of: Data("ENDHDR\n".utf8)))
        let header = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        let lines = header.split(separator: "\n").map(String.init)
        #expect(lines.first == "P7")
        #expect(lines.contains("WIDTH \(f.width)") && lines.contains("HEIGHT \(f.height)"))
        #expect(lines.contains("DEPTH \(f.channels)") && lines.contains("MAXVAL \((1 << f.bits) - 1)"))
        var expected = Data()
        for i in 0..<(f.width * f.height) { for c in 0..<f.channels {
            if f.bits > 8 { expected.append(UInt8(pixels[c][i] >> 8)) }
            expected.append(UInt8(truncatingIfNeeded: pixels[c][i]))
        } }
        #expect(data[end.upperBound...] == expected)
    }
    #endif
}
