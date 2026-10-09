import Foundation
let base = CommandLine.arguments[1]
let encoded = try Data(contentsOf: URL(fileURLWithPath: base + "/mixed-q11-m0.br"))
let expected = try Data(contentsOf: URL(fileURLWithPath: base + "/mixed.raw"))
for _ in 0..<10 {
    let result = try BrotliDecoder.decode(encoded, expectedOutputSize: expected.count, policy: BrotliPolicy())
    guard result == expected else { throw BrotliError.malformed("Benchmark output mismatch") }
}
var samples = [Double]()
for _ in 0..<7 {
    let start = ContinuousClock.now
    for _ in 0..<200 {
        let result = try BrotliDecoder.decode(encoded, expectedOutputSize: expected.count, policy: BrotliPolicy())
        guard result == expected else { throw BrotliError.malformed("Benchmark output mismatch") }
    }
    let elapsed = start.duration(to: .now).components
    samples.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
}
let data = try JSONSerialization.data(withJSONObject: ["configuration":"standalone swiftc -O; exact successor Brotli sources", "decodedBytesPerIteration":expected.count, "encodedBytes":encoded.count, "iterationsPerSample":200, "warmups":10, "sampleSeconds":samples, "medianMiBPerSecond": Double(expected.count * 200) / 1048576 / samples.sorted()[3]], options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
