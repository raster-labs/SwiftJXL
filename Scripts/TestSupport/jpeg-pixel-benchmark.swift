// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
#if PREDECESSOR
import JXLSwift
typealias Frame = ImageFrame
#else
import SwiftJXL
typealias Frame = DecodedImage
#endif
@main struct JPEGPixelBenchmark {
    @concurrent static func run() async throws {
        let a = CommandLine.arguments
        guard a.count == 4 else { throw NSError(domain: "arguments", code: 1) }
        let input = try Data(contentsOf: URL(fileURLWithPath: a[2]))
        #if PREDECESSOR
        func op() async throws -> Frame { try JPEGDecoder.decode(input) }
        func pixels(_ frame: Frame) throws -> Data { Data(frame.data) }
        #else
        let decoder = try Decoder()
        let options = DecodeOptions(resourceLimits: try .init(maximumWorkers: 1), executionPolicy: .scalarCPU)
        func op() async throws -> Frame { try await decoder.decodeJPEG(input, interpretingAs: .srgb, options: options) }
        func pixels(_ frame: Frame) throws -> Data { try frame.image.storage.withUnsafeBytes { Data($0) } }
        #endif
        let first = try await op(), expected = try pixels(first)
        #if PREDECESSOR
        let width = first.width, height = first.height, channels = first.channels
        #else
        let width = first.image.descriptor.width, height = first.image.descriptor.height, channels = first.image.descriptor.components.count
        #endif
        if a[1] == "preflight" {
            try expected.write(to: URL(fileURLWithPath: a[3]))
            print("{\"width\":\(width),\"height\":\(height),\"channels\":\(channels)}")
            return
        }
        var times: [Double] = [], heap = malloc_statistics_t(), retained: [Int] = []
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        for i in 0..<15 {
            let start = ContinuousClock.now
            let frame = try await op()
            let elapsed = start.duration(to: .now).components
            guard try pixels(frame) == expected else { throw NSError(domain: "repeat pixels", code: 2) }
            if i >= 5 { times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) }
            malloc_zone_statistics(nil, &heap)
            if i >= 5 { retained.append(Int(heap.size_in_use)) }
        }
        var rss = rusage(); guard getrusage(RUSAGE_SELF, &rss) == 0 else { throw NSError(domain: "rss", code: 3) }
        let result: [String: Any] = ["warmups":5,"milliseconds":times,"width":width,"height":height,"channels":channels,
            "processPeakRSSBytes":rss.ru_maxrss,"retainedProcessHeapBytes":retained,
            "thermalStart":thermal,"thermalEnd":ProcessInfo.processInfo.thermalState.rawValue]
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
    }
    static func main() async { do { try await run() } catch { print("FAILED: \(error)"); exit(1) } }
}
