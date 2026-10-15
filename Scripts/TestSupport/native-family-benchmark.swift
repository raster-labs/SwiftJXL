// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
#if PREDECESSOR
import JXLSwift
#else
import SwiftJXL
#endif
@main struct NativeBenchmark {
    @concurrent static func run() async throws {
        let a = CommandLine.arguments
        let jpeg = try Data(contentsOf: URL(fileURLWithPath: a[2]))
        #if !PREDECESSOR
        let limits = try ResourceLimits(maximumCompressedBytes: 64 << 20, maximumDecodedBytes: 64 << 20,
            maximumWorkspaceBytes: 512 << 20, maximumPixels: 2048 * 2048, maximumDimension: 2048,
            maximumMetadataBytes: 8 << 20, maximumWorkers: 1, maximumMemoryBytes: 1024 << 20)
        let options = TranscodeOptions(resourceLimits: limits, executionPolicy: .scalarCPU)
        let transcoder = try Transcoder()
        #endif
        func op(_ data: Data, forward: Bool) async throws -> Data {
            #if PREDECESSOR
            return try await (forward ? JXLEncoder().encodeLosslessJPEG(data).data : JXLDecoder().decodeLosslessJPEG(data))
            #else
            let result = try await transcoder.transcode(data, to: forward ? .jpegXL : .jpeg, options: options)
            guard result.report.fidelity == .originalBitstream else { throw NSError(domain: "fidelity", code: 1) }
            return result.data
            #endif
        }
        if a[1] == "preflight" {
            let encoded = try await op(jpeg, forward: true)
            try encoded.write(to: URL(fileURLWithPath: a[3]))
            guard try await op(encoded, forward: false) == jpeg else { throw NSError(domain: "original bytes", code: 2) }
            print("{\"exactOriginalJPEG\":true,\"outputBytes\":\(encoded.count)}")
            return
        }
        let encoded = try Data(contentsOf: URL(fileURLWithPath: a[3]))
        let forward = a[1] == "forward", input = forward ? jpeg : encoded, expected = forward ? encoded : jpeg
        var times: [Double] = [], heap = malloc_statistics_t(), retained: [Int] = []
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        for i in 0..<15 {
            let start = ContinuousClock.now
            let output = try await op(input, forward: forward)
            let t = start.duration(to: .now).components
            guard output == expected else { throw NSError(domain: "timed bytes", code: 3) }
            if i >= 5 { times.append(Double(t.seconds) * 1000 + Double(t.attoseconds) / 1e15) }
            malloc_zone_statistics(nil, &heap)
            if i >= 5 { retained.append(Int(heap.size_in_use)) }
        }
        var rss = rusage(); guard getrusage(RUSAGE_SELF, &rss) == 0 else { throw NSError(domain: "RSS", code: 4) }
        let result: [String: Any] = ["warmups":5,"milliseconds":times,"outputBytes":encoded.count,
            "processPeakRSSBytes":rss.ru_maxrss,"retainedProcessHeapBytes":retained,
            "thermalStart":thermal,"thermalEnd":ProcessInfo.processInfo.thermalState.rawValue]
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
    }
    static func main() async { do { try await run() } catch { print("FAILED: \(error)"); exit(1) } }
}
