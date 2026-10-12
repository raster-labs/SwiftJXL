// SPDX-License-Identifier: Apache-2.0
// Migration validation harness; not production codec code.
import Foundation
@main struct Benchmark {
    static func main() throws {
        var reports: [[String: Any]] = []
        for horizontal in [true, false] {
            let w = horizontal ? 128 : 256, h = horizontal ? 256 : 128
            let low = (0..<(w*h)).map { Int32(($0 * 13) % 65536) }
            let high = (0..<(w*h)).map { Int32(($0 * 7) % 512) - 256 }
            #if BASELINE
            let ll = ModularChannel(width: w, height: h, hshift: horizontal ? 1 : 0, vshift: horizontal ? 0 : 1, pixels: low)
            let residual = ModularChannel(width: w, height: h, hshift: ll.hshift, vshift: ll.vshift, pixels: high)
            #else
            let ll = try ModularChannel(width: w, height: h, hshift: horizontal ? 1 : 0, vshift: horizontal ? 0 : 1, pixels: low)
            let residual = try ModularChannel(width: w, height: h, hshift: ll.hshift, vshift: ll.vshift, pixels: high)
            #endif
            var times: [Double] = [], checksum: Int64 = 0
            for trial in 0..<10 {
                #if !BASELINE
                let budget = try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: 1<<30,
                    maximumMemoryBytes: 1<<30, maximumDecodedBytes: 1<<30, maximumCompressedBytes: 1<<30,
                    deadline: .now.advanced(by: .seconds(120)))
                #endif
                let start = DispatchTime.now().uptimeNanoseconds
                for iteration in 0..<32 {
                    #if BASELINE
                    let out = try horizontal ? SpecSqueeze.inverseHorizontal(ll: ll, residual: residual) : SpecSqueeze.inverseVertical(ll: ll, residual: residual)
                    #else
                    let out = try SpecSqueeze.inverse(ll: ll, residual: residual, horizontal: horizontal, budget: budget)
                    #endif
                    checksum += Int64(out.pixels[iteration * 197 % out.pixels.count])
                }
                let microseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 32000
                if trial >= 3 { times.append(microseconds) }
            }
            reports.append(["horizontal": horizontal, "samples": 65536, "median_us": times.sorted()[3], "trials_us": times, "checksum": checksum])
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys]), as: UTF8.self))
    }
}
