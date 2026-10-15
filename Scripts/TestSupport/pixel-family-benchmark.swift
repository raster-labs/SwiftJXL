// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
#if PREDECESSOR
import JXLSwift
#else
import SwiftJXL
#endif

private struct BenchError: Error { let message: String }
@main struct FamilyBenchmark {
    static func require(_ yes: Bool, _ message: String) throws {
        if !yes { throw BenchError(message: message) }
    }
    @concurrent static func run() async throws {
        // family operation source.pam frameCount distance iterations outputPrefix [sharedInput.jxl]
        let a = CommandLine.arguments
        guard a.count == 8 || a.count == 9, let count = Int(a[4]), (1...8).contains(count),
              let distance = Float(a[5]), distance.isFinite, distance > 0,
              let iterations = Int(a[6]), (0...100).contains(iterations),
              ["modular", "vardct"].contains(a[1]), ["encode", "decode"].contains(a[2]) else {
            throw BenchError(message: "arguments")
        }
        let lossy = a[1] == "vardct", operation = a[2], prefix = a[7]
        let file = try Data(contentsOf: URL(fileURLWithPath: a[3]))
        guard let end = file.range(of: Data("ENDHDR\n".utf8)) else { throw BenchError(message: "PAM header") }
        var fields: [String: String] = [:]
        for line in String(decoding: file[..<end.lowerBound], as: UTF8.self).split(separator: "\n") {
            let pair = line.split(separator: " ", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        guard let width = fields["WIDTH"].flatMap(Int.init), let height = fields["HEIGHT"].flatMap(Int.init),
              let channels = fields["DEPTH"].flatMap(Int.init), let maxval = fields["MAXVAL"].flatMap(Int.init),
              (1...2048).contains(width), (1...2048).contains(height), (1...4).contains(channels),
              [255,65535].contains(maxval) else { throw BenchError(message: "PAM shape") }
        let bits = maxval == 255 ? 8 : 16, sampleBytes = bits / 8, samples = width * height * channels
        try require(file.count - end.upperBound == samples * sampleBytes, "PAM payload")
        var expected: [[UInt8]] = []
        for frame in 0..<count {
            var bytes = [UInt8](repeating: 0, count: samples * sampleBytes)
            for i in 0..<samples {
                let offset = end.upperBound + i * sampleBytes
                let raw = sampleBytes == 1 ? Int(file[offset]) : Int(file[offset]) << 8 | Int(file[offset + 1])
                let value = (raw + frame * 17) & maxval
                bytes[i * sampleBytes] = UInt8(truncatingIfNeeded: value)
                if sampleBytes == 2 { bytes[i * 2 + 1] = UInt8(value >> 8) }
            }
            expected.append(bytes)
        }
        let durations = (0..<count).map { UInt32(10 + $0 * 5) }
        #if PREDECESSOR
        let workerPolicy = "predecessor-native"
        let sources = expected.map { bytes -> ImageFrame in
            var frame = ImageFrame(width: width, height: height, channels: channels,
                pixelType: bits == 8 ? .uint8 : .uint16, colorSpace: channels < 3 ? .grayscale : .sRGB,
                alphaChannels: channels % 2 == 0 ? 1 : 0)
            frame.data = bytes; return frame
        }
        let encoder = JXLEncoder(options: .init(mode: lossy ? .distance(distance) : .lossless,
            effort: .falcon, containerWrap: false, frameDurations: durations))
        let decoder = JXLDecoder()
        func encode() async throws -> Data {
            let result = try await (count == 1 ? encoder.encode(sources[0]) : encoder.encode(sources))
            try require(result.stats.wasLossless == !lossy, "Predecessor changed requested fidelity")
            return result.data
        }
        func decode(_ input: Data) async throws -> (pixels: [[UInt8]], milliseconds: Double) {
            let start = ContinuousClock.now
            let frames = try await (count == 1 ? [decoder.decode(input)] : decoder.decodeAll(input))
            let elapsed = start.duration(to: .now).components
            try require(frames.count == count, "Decoded frame count")
            let pixels = try frames.enumerated().map { index, frame in
                try require(frame.width == width && frame.height == height && frame.channels == channels, "Decoded geometry")
                try require(frame.data.count == samples * sampleBytes, "Predecessor decoded precision")
                if !lossy { try require(frame.data == expected[index], "Predecessor lossless samples") }
                if bits == 16 { return frame.data }
                return frame.data.flatMap { [$0, UInt8(0)] }
            }
            return (pixels, Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        #else
        let workerPolicy = ProcessInfo.processInfo.environment["SWIFTJXL_BENCHMARK_WORKERS"] ?? "1"
        let workerLimit: Int
        if workerPolicy == "default" { workerLimit = ResourceLimits.default.maximumWorkers }
        else {
            guard let value = Int(workerPolicy), (1...8).contains(value) else {
                throw BenchError(message: "Worker policy must be default or 1...8")
            }
            workerLimit = value
        }
        let roles: [ComponentRole] = (channels < 3 ? [.grey] : [.red,.green,.blue]) + (channels % 2 == 0 ? [.alpha] : [])
        let plane = try PlaneDescriptor(width: width, height: height, components: Array(roles.indices),
            sampleStride: sampleBytes, pixelStride: channels * sampleBytes,
            rowBytes: width * channels * sampleBytes, byteCount: samples * sampleBytes)
        let descriptor = try ImageDescriptor(width: width, height: height, storageBits: bits, meaningfulBits: bits,
            components: roles, colour: channels < 3 ? .greyscale : .rgb,
            alpha: channels % 2 == 0 ? .straight : .absent, planes: [plane])
        let sources = try expected.map { bytes in
            try ImageDestination.allocate(descriptor: descriptor).write { raw in
                for i in bytes.indices { raw[i] = bytes[i] }
            }
        }
        let limits = try ResourceLimits(maximumWorkspaceBytes: 2 * 1024 * 1024 * 1024,
            maximumWorkers: workerLimit, maximumMemoryBytes: 3 * 1024 * 1024 * 1024)
        let encodeOptions = EncodeOptions(resourceLimits: limits), decodeOptions = DecodeOptions(resourceLimits: limits)
        let configuration = try EncoderConfiguration(mode: lossy ? .lossy : .lossless,
            codecOptions: .init(varDCT: lossy ? .init(distance: distance) : nil))
        let encoder = try Encoder(configuration: configuration), decoder = try Decoder()
        let animationFrames = try sources.enumerated().map { try AnimationInputFrame(image: $0.element, durationTicks: durations[$0.offset]) }
        func encode() async throws -> Data {
            if count == 1 { return try await encoder.encode(sources[0], options: encodeOptions).data }
            return try await encoder.encodeAnimation(animationFrames, animation: .init(ticksPerSecondNumerator: 100), options: encodeOptions).encoded.data
        }
        func decode(_ input: Data) async throws -> (pixels: [[UInt8]], milliseconds: Double) {
            let frames: [Image]
            let start = ContinuousClock.now
            let elapsed: (seconds: Int64, attoseconds: Int64)
            if count == 1 {
                let result = try await decoder.decode(input, options: decodeOptions)
                elapsed = start.duration(to: .now).components
                frames = [result.image]
            }
            else {
                let result = try await decoder.decodeAll(input, options: decodeOptions)
                elapsed = start.duration(to: .now).components
                try require(result.frames.map(\.durationTicks) == durations, "Animation durations")
                frames = result.frames.map(\.decoded.image)
            }
            try require(frames.count == count, "Decoded frame count")
            let pixels = try frames.enumerated().map { index, frame in
                try require(frame.descriptor.width == width && frame.descriptor.height == height &&
                    frame.descriptor.components.count == channels && frame.descriptor.meaningfulBits == bits, "Decoded descriptor")
                let bytes = try frame.storage.withUnsafeBytes { Array($0) }
                try require(bytes.count == samples * 2, "Canonical allocation")
                if !lossy {
                    for i in 0..<samples {
                        try require(bytes[i * 2] == expected[index][i * sampleBytes] &&
                            bytes[i * 2 + 1] == (bits == 8 ? 0 : expected[index][i * 2 + 1]), "Successor lossless samples")
                    }
                }
                return bytes
            }
            return (pixels, Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        #endif
        let ownEncoded = try await encode()
        try ownEncoded.write(to: URL(fileURLWithPath: prefix + ".jxl"))
        let input = try a.count == 9 ? Data(contentsOf: URL(fileURLWithPath: a[8])) : ownEncoded
        let reference = try await decode(input).pixels
        for (index, bytes) in reference.enumerated() {
            try Data(bytes).write(to: URL(fileURLWithPath: prefix + "-frame-\(index).u16le"))
        }
        var times: [Double] = [], retained: [Int] = [], heap = malloc_statistics_t()
        let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
        let warmups = iterations == 0 ? 0 : 5
        for i in 0..<(warmups + iterations) {
            let start = ContinuousClock.now
            if operation == "encode" {
                let result = try await encode()
                let elapsed = start.duration(to: .now).components
                if i >= warmups { times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) }
                try require(result == ownEncoded, "Nondeterministic encode")
            } else {
                let result = try await decode(input)
                if i >= warmups { times.append(result.milliseconds) }
                try require(result.pixels == reference, "Nondeterministic decode")
            }
            malloc_zone_statistics(nil, &heap)
            if i >= warmups { retained.append(Int(heap.size_in_use)) }
        }
        var usage = rusage(); try require(getrusage(RUSAGE_SELF, &usage) == 0, "RSS")
        var report: [String: Any] = ["family": a[1], "operation": operation, "width": width, "height": height,
            "channels": channels, "bits": bits, "frameCount": count, "distance": distance,
            "encodedBytes": ownEncoded.count, "inputBytes": input.count, "warmups": warmups,
            "milliseconds": times, "retainedProcessHeapBytes": retained, "processPeakRSSBytes": usage.ru_maxrss,
            "thermalStart": thermalStart, "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue,
            "workerPolicy": workerPolicy,
            "caller": "generic executor", "note": "API calls are timed; sample materialisation and validation follow outside timing. Heap is a process endpoint, not peak workspace or leak proof. Queue depth one; all frames in each sequence are retained by decodeAll. Successor worker policy is recorded with explicit 2GiB workspace/3GiB aggregate; predecessor native policy is unchanged."]
        #if !PREDECESSOR
        report["maximumWorkers"] = limits.maximumWorkers
        #endif
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
    static func main() async {
        do { try await run() }
        catch { print("FAILED: \(error)"); exit(1) }
    }
}
