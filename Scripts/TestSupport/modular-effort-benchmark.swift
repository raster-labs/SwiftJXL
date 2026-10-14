// SPDX-License-Identifier: Apache-2.0
// Qualification-only core probe; public encoding still uses effort 3.
import Foundation
import Darwin
import SwiftJXLCore

@main struct EffortProbe {
    static func main() throws {
        let a = CommandLine.arguments
        guard a.count == 9, let width = Int(a[1]), let height = Int(a[2]),
              let channels = Int(a[3]), let bits = Int(a[4]), let effort = Int(a[5]),
              let iterations = Int(a[6]), (1...1025).contains(width), (1...1025).contains(height),
              [1, 3, 4].contains(channels), [8, 12, 16].contains(bits),
              (1...9).contains(effort), (0...100).contains(iterations) else {
            throw NSError(domain: "effort probe arguments", code: 1)
        }
        let pattern = a[7], maximum = (1 << bits) - 1
        var planes = [[UInt16]](repeating: [UInt16](repeating: 0, count: width * height), count: channels)
        var random: UInt32 = 20261013
        for i in 0..<(width * height) { for c in 0..<channels {
            random = random &* 1664525 &+ 1013904223
            let texture = Int(random >> 8) & maximum
            let ramp = (i * 71 + (i / width) * 37 + c * 113) & maximum
            let value = pattern == "flat" ? maximum / 3 : pattern == "noise" ? texture :
                pattern == "mixed" && i % width >= width / 2 ? texture : ramp
            planes[c][i] = UInt16(value)
        } }
        func encode() throws -> Data {
            switch channels {
            case 1:
                if bits == 8 {
                    return try SpecModularEncoder.encodeGrayscale8(width: width, height: height,
                        pixels: planes[0].map(UInt8.init), effort: effort)
                }
                return try SpecModularEncoder.encodeGrayscale16(width: width, height: height,
                    bitsPerSample: UInt32(bits), pixelsInt32: planes[0].map(Int32.init), effort: effort)
            case 3:
                if bits == 8 {
                    return try SpecModularEncoder.encodeRGB8(width: width, height: height,
                        r: planes[0].map(UInt8.init), g: planes[1].map(UInt8.init), b: planes[2].map(UInt8.init), effort: effort)
                }
                return try SpecModularEncoder.encodeRGB16(width: width, height: height,
                    bitsPerSample: UInt32(bits), r: planes[0], g: planes[1], b: planes[2], effort: effort)
            default:
                if bits == 8 {
                    return try SpecModularEncoder.encodeRGBA8(width: width, height: height,
                        r: planes[0].map(UInt8.init), g: planes[1].map(UInt8.init), b: planes[2].map(UInt8.init), a: planes[3].map(UInt8.init), effort: effort)
                }
                return try SpecModularEncoder.encodeRGBA16(width: width, height: height,
                    bitsPerSample: UInt32(bits), r: planes[0], g: planes[1], b: planes[2], a: planes[3], effort: effort)
            }
        }
        let expected = try encode()
        try expected.write(to: URL(fileURLWithPath: a[8]))
        var samples: [Double] = []
        let warmups = iterations == 0 ? 0 : 5
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        for i in 0..<(warmups + iterations) {
            let start = ContinuousClock.now
            let result = try encode()
            let elapsed = start.duration(to: .now).components
            guard result == expected else { throw NSError(domain: "unstable codestream", code: 2) }
            if i >= warmups { samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) }
        }
        var usage = rusage(); guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw NSError(domain: "rusage", code: 3) }
        let result: [String: Any] = ["width": width, "height": height, "channels": channels, "bits": bits,
            "effort": effort, "pattern": pattern, "warmups": warmups, "milliseconds": samples,
            "encodedBytes": expected.count, "processPeakRSSBytes": usage.ru_maxrss,
            "thermalStart": thermal, "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue,
            "scope": "Unexposed core effort qualification with serial fallback; no public admission envelope or peak-workspace claim."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
