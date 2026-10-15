// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

/// Cross both axes, the 512-pixel group corner and 4096-pixel DC-group
/// boundaries. Large explicit allowances belong to this correctness corpus;
/// production defaults are unchanged and their refusal is tested separately.
#if os(macOS) || os(Linux)
@Suite(.serialized)
struct ModularGroupBoundaryTests {
    struct Case: Sendable {
        let width: Int, height: Int, channels: Int, bits: Int, effort: Int
        var fixture: ModularProfileCase {
            .init(width: width, height: height, channels: channels, bits: bits)
        }
        func budget(workers: Int = 1, workspace: Int = 4 * 1024 * 1024 * 1024) throws -> ScalarOperationBudget {
            try fixture.budget(workers: workers, workspace: workspace,
                memory: 6 * 1024 * 1024 * 1024,
                decoded: 128 * 1024 * 1024, compressed: 128 * 1024 * 1024)
        }
    }
    static let cases: [Case] = [
        .init(width: 511, height: 511, channels: 1, bits: 8, effort: 3),
        .init(width: 512, height: 512, channels: 2, bits: 16, effort: 7),
        .init(width: 513, height: 513, channels: 1, bits: 12, effort: 3),
        .init(width: 513, height: 513, channels: 2, bits: 10, effort: 8),
        .init(width: 513, height: 513, channels: 3, bits: 12, effort: 9),
        .init(width: 513, height: 513, channels: 4, bits: 16, effort: 3),
        .init(width: 4095, height: 9, channels: 2, bits: 13, effort: 3),
        .init(width: 4096, height: 9, channels: 2, bits: 13, effort: 7),
        .init(width: 4097, height: 9, channels: 2, bits: 13, effort: 9),
        .init(width: 9, height: 4095, channels: 3, bits: 8, effort: 3),
        .init(width: 9, height: 4096, channels: 3, bits: 8, effort: 7),
        .init(width: 9, height: 4097, channels: 3, bits: 8, effort: 9),
        .init(width: 4097, height: 513, channels: 1, bits: 16, effort: 3),
        .init(width: 513, height: 4097, channels: 2, bits: 8, effort: 3),
        .init(width: 4097, height: 4097, channels: 1, bits: 12, effort: 3)
    ]

    @Test(arguments: Array(cases.indices))
    func twoDimensionalGroupsAndDCBoundaries(_ index: Int) throws {
        let c = Self.cases[index], f = c.fixture, pixels = f.pixels()
        let serial = try f.encode(pixels, effort: c.effort, budget: c.budget())
        #expect(try f.encode(pixels, effort: c.effort, budget: c.budget(workers: 8)) == serial)
        let decoded = try ModularFrameDecoder.decode(serial, budget: c.budget())
        #expect(decoded.bitsPerSample == c.bits)
        #expect(decoded.alphaAssociated == (c.channels % 2 == 0 ? false : nil))
        try #require(decoded.image.channels.count == c.channels)
        for channel in 0..<c.channels {
            #expect(decoded.image.channels[channel].pixels == pixels[channel].map(Int32.init))
        }
        // Reversed plane order and separate per-plane row strides make a wrong
        // group origin, channel mapping or endian choice observable at the edge.
        var next = 7
        var layouts: [ModularChannelLayout] = []
        for channel in 0..<c.channels {
            let row = c.width * 2 + 3 + channel
            layouts.append(try ModularChannelLayout(width: c.width, height: c.height,
                offset: next, rowBytes: row, pixelStride: 2, storageBits: 16, littleEndian: false))
            next += row * c.height + 11
        }
        layouts.reverse()
        var actual = [UInt8](repeating: 0xA5, count: next), expected = actual
        for channel in 0..<c.channels { for i in 0..<(c.width * c.height) {
            let layout = layouts[channel]
            let p = layout.offset + i / c.width * layout.rowBytes + i % c.width * 2
            expected[p] = UInt8(pixels[channel][i] >> 8)
            expected[p + 1] = UInt8(truncatingIfNeeded: pixels[channel][i])
        } }
        let audit = ScalarStorageAudit()
        try ScalarStorageAudit.$current.withValue(audit) {
            let prepared = try ModularFrameDecoder.prepare(serial, budget: c.budget())
            try actual.withUnsafeMutableBytes { try prepared.decode(into: $0, layouts: layouts) }
        }
        #expect(actual == expected)
        #expect(audit.snapshot.finalPixelAllocations == 0)
        #if os(macOS) || os(Linux)
        if let binary = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"] {
            try ModularProfileTests().oracle(serial, fixture: f, pixels: pixels, effort: c.effort, binary: binary)
            try independentlyEncoded(c, pixels: pixels, binary: binary)
        }
        #endif
    }

    @Test(arguments: [3, 4, 13, 14])
    func defaultWorkspaceStillRefusesLargeProfiles(_ index: Int) throws {
        let c = Self.cases[index], pixels = c.fixture.pixels()
        let budget = try c.budget(workers: 8, workspace: 512 * 1024 * 1024)
        do {
            _ = try c.fixture.encode(pixels, effort: c.effort, budget: budget)
            Issue.record("Default workspace admitted a larger explicitly budgeted profile")
        } catch ScalarModularError.resourceLimit {}
    }

    #if os(macOS) || os(Linux)
    private func independentlyEncoded(_ c: Case, pixels: [[UInt16]], binary: String) throws {
        let saved = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_OUTPUT"]
        let root = saved.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("group-reference-\(c.width)x\(c.height)-c\(c.channels)-b\(c.bits)-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { if saved == nil { try? FileManager.default.removeItem(at: dir) } }
        let tuple = ["GRAYSCALE", "GRAYSCALE_ALPHA", "RGB", "RGB_ALPHA"][c.channels - 1]
        var source = Data("P7\nWIDTH \(c.width)\nHEIGHT \(c.height)\nDEPTH \(c.channels)\nMAXVAL \((1 << c.bits) - 1)\nTUPLTYPE \(tuple)\nENDHDR\n".utf8)
        for i in 0..<(c.width * c.height) { for channel in 0..<c.channels {
            if c.bits > 8 { source.append(UInt8(pixels[channel][i] >> 8)) }
            source.append(UInt8(truncatingIfNeeded: pixels[channel][i]))
        } }
        let input = dir.appendingPathComponent("source.pam"), output = dir.appendingPathComponent("reference.jxl")
        try source.write(to: input)
        let log = dir.appendingPathComponent("oracle.log")
        try Data().write(to: log)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary + "/cjxl")
        process.arguments = [input.path, output.path, "--distance=0", "--modular=1", "--effort=3", "--num_threads=2"]
        process.standardOutput = handle; process.standardError = handle
        try process.run(); process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let data = try Data(contentsOf: output)
        let decoded = try ModularFrameDecoder.decode(data, budget: c.budget())
        #expect(decoded.bitsPerSample == c.bits)
        try #require(decoded.image.channels.count == c.channels)
        for channel in 0..<c.channels {
            #expect(decoded.image.channels[channel].pixels == pixels[channel].map(Int32.init))
        }
    }
    #endif
}
#endif
