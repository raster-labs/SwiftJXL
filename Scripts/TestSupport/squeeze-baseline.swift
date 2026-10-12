// SPDX-License-Identifier: Apache-2.0
import Foundation
@main struct SqueezeVectors {
    static func main() throws {
        var cases: [[String: Any]] = []
        let samples: [Int32] = [0, 1, -1, 32767, -32768, 65535, .min, .max, 127, -255, 511]
        for horizontal in [true, false] {
            for length in [1, 2, 3, 8, 9, 33] {
                let width = horizontal ? length : 7, height = horizontal ? 7 : length
                let lw = horizontal ? (width + 1) / 2 : width
                let lh = horizontal ? height : (height + 1) / 2
                let rw = horizontal ? width / 2 : width
                let rh = horizontal ? height : height / 2
                let low = (0..<(lw * lh)).map { samples[$0 % samples.count] }
                let high = (0..<(rw * rh)).map { samples[($0 * 3 + 5) % samples.count] }
                let ll = ModularChannel(width: lw, height: lh,
                    hshift: horizontal ? 1 : 0, vshift: horizontal ? 0 : 1, pixels: low)
                let residual = ModularChannel(width: rw, height: rh,
                    hshift: ll.hshift, vshift: ll.vshift, pixels: high)
                let out = try horizontal ? SpecSqueeze.inverseHorizontal(ll: ll, residual: residual)
                                         : SpecSqueeze.inverseVertical(ll: ll, residual: residual)
                cases.append(["horizontal": horizontal, "width": width, "height": height,
                              "low": low, "high": high, "output": out.pixels])
            }
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: cases, options: [.sortedKeys]), as: UTF8.self))
    }
}
