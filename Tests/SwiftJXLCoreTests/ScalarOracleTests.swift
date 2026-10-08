// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

#if os(macOS) || os(Linux)
/// Opt-in independent tests. Missing tools are a skipped gate, never a success.
/// CI/native qualification sets SWIFTJXL_ORACLE_BIN to pinned cjxl/djxl binaries.
struct ScalarOracleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"] != nil),
          arguments: [9, 10, 12, 14, 16])
    func independentBothDirections(bits: Int) throws {
        let binaryDirectory = try #require(ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"])
        let root = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_OUTPUT"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("scalar-\(bits)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_OUTPUT"] == nil {
            try? FileManager.default.removeItem(at: directory)
        } }
        for (width, height) in [(1, 1), (2, 3), (31, 17), (128, 129), (255, 17)] {
            let stem = "\(width)x\(height)"
            let maximum = (Int32(1) << bits) - 1
            var samples = (0..<(width * height)).map { Int32(($0 * 7919) ^ ($0 >> 2)) & maximum }
            samples[0] = maximum
            if samples.count > 1 { samples[1] = 0 }
            let expected = samples.flatMap { [UInt8(truncatingIfNeeded: $0 >> 8), UInt8(truncatingIfNeeded: $0)] }
            var pgm = Data("P5\n\(width) \(height)\n\(maximum)\n".utf8)
            pgm.append(contentsOf: expected)
            let input = directory.appendingPathComponent(stem + ".pgm")
            try pgm.write(to: input)
            let native = directory.appendingPathComponent(stem + "-native.jxl")
            try SpecModularEncoder.encodeGrayscale16(width: width, height: height,
                bitsPerSample: UInt32(bits), pixelsInt32: samples, effort: 3).write(to: native)
            let oraclePGM = directory.appendingPathComponent(stem + "-oracle.pgm")
            try run(binaryDirectory + "/djxl", [native.path, oraclePGM.path, "--bits_per_sample=\(bits)", "--quiet"], in: directory)
            let actual = try Data(contentsOf: oraclePGM)
            // PNM's max value declares the precision. Do not normalise samples or headers.
            #expect(actual == pgm)
            let oracleJXL = directory.appendingPathComponent(stem + "-oracle.jxl")
            try run(binaryDirectory + "/cjxl", [input.path, oracleJXL.path, "-d", "0", "-e", "1", "--container=0", "--quiet"], in: directory)
            let oracleData = try Data(contentsOf: oracleJXL)
            let decoded = try ScalarModularDecoder.decode(oracleData)
            let frame = try ScalarModularDecoder.prepare(oracleData)
            let stride = width * 2 + 6
            let layout = try ScalarPlaneLayout(width: width, height: height, rowBytes: stride,
                                               littleEndian: false)
            var shared = [UInt8](repeating: 0xa5, count: height * stride)
            try shared.withUnsafeMutableBytes { raw in try frame.decode(into: raw, layout: layout) }
            for y in 0..<height {
                #expect(Array(shared[(y * stride)..<(y * stride + width * 2)])
                        == Array(expected[(y * width * 2)..<((y + 1) * width * 2)]))
                #expect(shared[(y * stride + width * 2)..<((y + 1) * stride)].allSatisfy { $0 == 0xa5 })
            }
            let sharedEncoded = try shared.withUnsafeBytes { raw in
                try ScalarModularEncoder.encode(raw, layout: layout, bitsPerSample: bits)
            }
            #expect(try Data(contentsOf: native) == sharedEncoded)
            #expect(decoded.width == width && decoded.height == height)
            #expect(decoded.bitsPerSample == bits)
            #expect(decoded.pixels == samples)
        }
    }

    private func run(_ executable: String, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let log = directory.appendingPathComponent("\(UUID().uuidString).log")
        #expect(FileManager.default.createFile(atPath: log.path, contents: nil))
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        try #require(process.terminationReason == .exit && process.terminationStatus == 0,
                     "Independent tool failed; inspect \(log.path)")
    }
}
#endif
