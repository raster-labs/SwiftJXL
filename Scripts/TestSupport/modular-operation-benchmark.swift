// SPDX-License-Identifier: Apache-2.0
// Test-only whole public-operation probe. Compile -O without sanitizers.
// PREDECESSOR selects the pinned JXLSwift public API; source pixels are identical.
import Foundation
import Darwin
#if PREDECESSOR
import JXLSwift
#else
import SwiftJXL
#endif

@main struct ModularOperationBenchmark {
    static func main() async throws {
        // operation width height channels bits iterations outputJXL [inputJXL]
        let args = CommandLine.arguments
        guard args.count == 8 || args.count == 9,
              ["encode", "decode", "caller"].contains(args[1]),
              let width = Int(args[2]), let height = Int(args[3]), let channels = Int(args[4]),
              let bits = Int(args[5]), let iterations = Int(args[6]),
              (1...1024).contains(width), (1...1024).contains(height),
              (1...4).contains(channels), [8, 16].contains(bits), (0...100).contains(iterations) else {
            throw NSError(domain: "benchmark arguments", code: 1)
        }
        let operation = args[1], sampleBytes = bits / 8, n = width * height
        let maximum = (1 << bits) - 1
        var expected = [UInt8](repeating: 0, count: n * channels * sampleBytes)
        for i in 0..<n { for c in 0..<channels {
            let value = (i * 71 + (i / width) * 37 + c * 113) & maximum
            let p = (i * channels + c) * sampleBytes
            expected[p] = UInt8(truncatingIfNeeded: value)
            if sampleBytes == 2 { expected[p + 1] = UInt8(truncatingIfNeeded: value >> 8) }
        } }
        #if PREDECESSOR
        let implementation = "JXLSwift pinned predecessor, native parallel map"
        var source = ImageFrame(width: width, height: height, channels: channels,
            pixelType: bits == 8 ? .uint8 : .uint16, colorSpace: channels < 3 ? .grayscale : .sRGB,
            alphaChannels: channels % 2 == 0 ? 1 : 0)
        source.data = expected
        let encoder = JXLEncoder(options: .init(mode: .lossless, effort: .falcon, containerWrap: false))
        let decoder = JXLDecoder()
        let ownEncoded = try await encoder.encode(source).data
        #else
        let implementation = "SwiftJXL, bounded scalar CPU"
        let roles: [ComponentRole] = (channels < 3 ? [.grey] : [.red, .green, .blue]) +
            (channels % 2 == 0 ? [.alpha] : [])
        let plane = try PlaneDescriptor(width: width, height: height, components: Array(roles.indices),
            sampleStride: sampleBytes, pixelStride: channels * sampleBytes,
            rowBytes: width * channels * sampleBytes, byteCount: expected.count)
        let descriptor = try ImageDescriptor(width: width, height: height, storageBits: bits, meaningfulBits: bits,
            components: roles, colour: channels < 3 ? .greyscale : .rgb,
            alpha: channels % 2 == 0 ? .straight : .absent, planes: [plane])
        let source = try ImageDestination.allocate(descriptor: descriptor).write { raw in
            for i in expected.indices { raw[i] = expected[i] }
        }
        let encoder = try Encoder(), decoder = try Decoder()
        let ownEncoded = try await encoder.encode(source).data
        #endif
        try ownEncoded.write(to: URL(fileURLWithPath: args[7]))
        let input = try args.count == 9 ? Data(contentsOf: URL(fileURLWithPath: args[8])) : ownEncoded
        var times: [Double] = [], heapDeltas: [Int] = []
        let warmups = iterations == 0 ? 0 : 5
        let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
        for iteration in 0..<(warmups + iterations) {
            #if !PREDECESSOR
            // Caller-owned storage is allocated before timing, as it is retained
            // by the caller. Allocating decode includes its own destination cost.
            let destination = operation == "caller" ? try ImageDestination.allocate(descriptor: descriptor) : nil
            #endif
            var heapBefore = malloc_statistics_t(), heapAfter = malloc_statistics_t()
            malloc_zone_statistics(nil, &heapBefore)
            let start = ContinuousClock.now
            let valid: Bool
            let elapsed: Duration
            if operation == "encode" {
                #if PREDECESSOR
                let result = try await encoder.encode(source).data
                #else
                let result = try await encoder.encode(source).data
                #endif
                elapsed = start.duration(to: .now)
                malloc_zone_statistics(nil, &heapAfter)
                valid = result == ownEncoded
            } else {
                #if PREDECESSOR
                guard operation == "decode" else { throw NSError(domain: "predecessor has no owning caller decode", code: 2) }
                let result = try await decoder.decode(input)
                elapsed = start.duration(to: .now)
                malloc_zone_statistics(nil, &heapAfter)
                valid = result.width == width && result.height == height && result.channels == channels && result.data == expected
                #else
                let result: DecodedImage
                if let destination { result = try await decoder.decode(input, into: destination) }
                else { result = try await decoder.decode(input) }
                elapsed = start.duration(to: .now)
                malloc_zone_statistics(nil, &heapAfter)
                valid = try result.image.storage.withUnsafeBytes { raw in
                    let stride = result.image.descriptor.storageBits / 8
                    for i in 0..<(n * channels) {
                        if raw[i * stride] != expected[i * sampleBytes] { return false }
                        if stride == 2 && raw[i * stride + 1] != (sampleBytes == 2 ? expected[i * sampleBytes + 1] : 0) { return false }
                    }
                    return true
                }
                if let destination {
                    guard result.image.storage.allocationID == destination.storage.allocationID else {
                        throw NSError(domain: "caller allocation replaced", code: 3)
                    }
                }
                #endif
            }
            guard valid else { throw NSError(domain: "benchmark fidelity mismatch", code: 4) }
            if iteration >= warmups {
                let components = elapsed.components
                times.append(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
                heapDeltas.append(Int(heapAfter.size_in_use) - Int(heapBefore.size_in_use))
            }
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw NSError(domain: "rusage", code: 5) }
        let report: [String: Any] = ["implementation": implementation, "operation": operation,
            "width": width, "height": height, "channels": channels, "bits": bits,
            "sourceBytes": expected.count, "encodedBytes": ownEncoded.count, "inputBytes": input.count,
            "warmups": warmups, "timedIterations": iterations, "milliseconds": times,
            "retainedHeapDeltaBytes": heapDeltas, "processPeakRSSBytes": usage.ru_maxrss,
            "thermalStart": thermalStart, "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processors": ProcessInfo.processInfo.processorCount,
            "note": "Heap deltas are retained process-heap observations, not peak algorithm workspace. RSS is process high-water, including setup/warmup. Predecessor uses native parallelism; successor uses bounded scalar execution."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
