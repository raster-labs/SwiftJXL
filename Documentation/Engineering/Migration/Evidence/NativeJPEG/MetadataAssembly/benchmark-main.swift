import Foundation

var rows: [[String: Any]] = []
for name in ["gray", "progressive-edge", "metadata-tail", "long-fill"] {
    let filename = name == "long-fill" ? "gray" : name
    var data = try Data(contentsOf: URL(fileURLWithPath: "Tests/SwiftJXLCoreTests/Fixtures/JPEG/\(filename).jpg"))
    if name == "long-fill" { data.insert(contentsOf: repeatElement(UInt8(0xff), count: 65536), at: data.count - 2) }
    let decoded = try JPEGCoefficientDecoder.decode(data, policy: JPEGCoefficientPolicy())
    for _ in 0..<20 { _ = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy()) }
    var samples: [Double] = [], bytes = 0
    for _ in 0..<7 {
        let start = ContinuousClock.now
        for _ in 0..<200 { bytes = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy()).bundle.count }
        let d = start.duration(to: .now).components
        samples.append((Double(d.seconds) * 1e6 + Double(d.attoseconds) / 1e12) / 200)
    }
    rows.append(["fixture": name, "sourceBytes": data.count, "bundleBytes": bytes,
                 "medianMicroseconds": samples.sorted()[3], "samplesMicroseconds": samples])
}
let report: [String: Any] = ["scope": "Native metadata assembly only, coefficient decode excluded; absolute new-stage timing, not a speedup claim",
                            "warmups": 20, "trials": 7, "iterationsPerTrial": 200, "fixtures": rows]
print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
