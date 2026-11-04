// SPDX-License-Identifier: Apache-2.0
// Controlled before/after probe for the Linux locking compatibility change.
import Foundation
import Glibc
import SwiftJXL

private struct ProbeError: Error { let message: String }

@main struct LinuxLockBenchmark {
    @concurrent static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 7, ["modular", "vardct"].contains(arguments[1]),
              ["encode", "decode"].contains(arguments[2]),
              let workers = Int(arguments[3]), (1...8).contains(workers),
              let size = Int(arguments[4]), (256...1024).contains(size),
              let iterations = Int(arguments[5]), (1...30).contains(iterations) else {
            throw ProbeError(message: "family operation workers size iterations output-prefix")
        }
        let family = arguments[1], operation = arguments[2], prefix = arguments[6]
        let rowBytes = size * 3 * 2
        let plane = try PlaneDescriptor(width: size, height: size, components: [0, 1, 2],
            sampleStride: 2, pixelStride: 6, rowBytes: rowBytes, byteCount: rowBytes * size)
        let descriptor = try ImageDescriptor(width: size, height: size, storageBits: 16,
            meaningfulBits: 16, components: [.red, .green, .blue], colour: .rgb,
            alpha: .absent, planes: [plane])
        var expected = [UInt8](repeating: 0, count: rowBytes * size)
        for y in 0..<size {
            for x in 0..<size {
                for channel in 0..<3 {
                    let value = UInt16(truncatingIfNeeded: x * 131 + y * 257 + channel * 8191 + (x * y % 97) * 31)
                    let offset = y * rowBytes + x * 6 + channel * 2
                    expected[offset] = UInt8(truncatingIfNeeded: value)
                    expected[offset + 1] = UInt8(value >> 8)
                }
            }
        }
        let image = try ImageDestination.allocate(descriptor: descriptor).write { bytes in
            for index in expected.indices { bytes[index] = expected[index] }
        }
        let limits = try ResourceLimits(maximumWorkspaceBytes: 768 * 1024 * 1024,
            maximumWorkers: workers, maximumMemoryBytes: 1024 * 1024 * 1024)
        let encoder = try Encoder(configuration: .init(mode: family == "modular" ? .lossless : .lossy,
            codecOptions: .init(varDCT: family == "vardct" ? .init(distance: 1) : nil)))
        let decoder = try Decoder()
        let encoded = try await encoder.encode(image, options: .init(resourceLimits: limits)).data
        let decoded = try await decoder.decode(encoded, options: .init(resourceLimits: limits)).image
        let reference = try decoded.storage.withUnsafeBytes { Array($0) }
        if family == "modular", reference != expected { throw ProbeError(message: "Lossless sample mismatch") }
        try encoded.write(to: URL(fileURLWithPath: prefix + ".jxl"))
        try Data(reference).write(to: URL(fileURLWithPath: prefix + ".raw"))
        var milliseconds: [Double] = []
        for index in 0..<(3 + iterations) {
            let start = ContinuousClock.now
            if operation == "encode" {
                let result = try await encoder.encode(image, options: .init(resourceLimits: limits)).data
                let elapsed = start.duration(to: .now).components
                if index >= 3 { milliseconds.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) }
                if result != encoded { throw ProbeError(message: "Nondeterministic encode") }
            } else {
                let result = try await decoder.decode(encoded, options: .init(resourceLimits: limits)).image
                let elapsed = start.duration(to: .now).components
                if index >= 3 { milliseconds.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) }
                if try result.storage.withUnsafeBytes({ Array($0) }) != reference {
                    throw ProbeError(message: "Nondeterministic decode")
                }
            }
        }
        var usage = rusage()
        guard getrusage(0, &usage) == 0 else { throw ProbeError(message: "getrusage") }
        let report: [String: Any] = ["family": family, "operation": operation, "workers": workers,
            "size": size, "iterations": iterations, "warmups": 3, "milliseconds": milliseconds,
            "encodedBytes": encoded.count, "processPeakRSSBytes": usage.ru_maxrss * 1024,
            "scope": "Public API latency and whole-process peak RSS; sample validation is outside timing. No copy/allocation or general throughput claim."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }

    static func main() async {
        do { try await run() }
        catch { print("Benchmark failed: \(error)"); exit(1) }
    }
}
