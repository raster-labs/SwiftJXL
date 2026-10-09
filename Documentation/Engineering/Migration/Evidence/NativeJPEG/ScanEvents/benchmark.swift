import Foundation
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let policy = try JPEGCoefficientPolicy(deadline: .now.advanced(by: .seconds(120)))
let expected = try JPEGCoefficientDecoder.decode(data, policy: policy).coefficients
for _ in 0..<100 { _ = try JPEGCoefficientDecoder.decode(data, policy: policy) }
var seconds: [Double] = []
for _ in 0..<7 {
    let start = ContinuousClock.now
    for _ in 0..<2000 {
        let value = try JPEGCoefficientDecoder.decode(data, policy: policy)
        guard value.coefficients == expected else { fatalError("Coefficient instability") }
    }
    let duration = start.duration(to: .now).components
    seconds.append(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
}
let report: [String: Any] = ["iterationsPerSample": 2000, "warmups": 100,
    "seconds": seconds, "medianMicrosecondsPerDecode": seconds.sorted()[3] * 1e6 / 2000,
    "inputBytes": data.count, "coefficientCount": expected.reduce(0) { $0 + $1.count }]
print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
