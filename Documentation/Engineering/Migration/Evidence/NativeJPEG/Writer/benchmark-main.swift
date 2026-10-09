import Foundation
var rows: [[String: Any]] = []
for name in ["gray", "progressive-edge", "metadata-tail", "long-fill", "large-eob"] {
    let directory = name == "large-eob" ? "JPEGEvents" : "JPEG"
    let filename = name == "long-fill" ? "gray" : name
    var data = try Data(contentsOf: URL(fileURLWithPath: "Tests/SwiftJXLCoreTests/Fixtures/\(directory)/\(filename).jpg"))
    if name == "long-fill" { data.insert(contentsOf: repeatElement(UInt8(0xff), count: 65536), at: data.count - 2) }
    let decoded = try JPEGCoefficientDecoder.decode(data, policy: JPEGCoefficientPolicy())
    let metadata = try JPEGReconstructionMetadata.encode(decoded, policy: JBRDPolicy()).box
    let warmups = name == "large-eob" ? 3 : 20, iterations = name == "large-eob" ? 10 : 200
    for _ in 0..<warmups {
        guard try JPEGReconstructionWriter.write(coefficients: decoded.coefficients, metadata: metadata,
            policy: JPEGReconstructionPolicy()) == data else { throw JPEGEntropyError.malformed }
    }
    var samples: [Double] = []
    for _ in 0..<7 {
        let start = ContinuousClock.now
        for _ in 0..<iterations {
            guard try JPEGReconstructionWriter.write(coefficients: decoded.coefficients, metadata: metadata,
                policy: JPEGReconstructionPolicy()) == data else { throw JPEGEntropyError.malformed }
        }
        let duration = start.duration(to: .now).components
        samples.append((Double(duration.seconds) * 1e6 + Double(duration.attoseconds) / 1e12) / Double(iterations))
    }
    rows.append(["fixture": name, "outputBytes": data.count, "warmups": warmups, "iterationsPerTrial": iterations,
                 "medianMicroseconds": samples.sorted()[3], "samplesMicroseconds": samples])
}
let report: [String: Any] = ["scope": "Native JPEG output only, plus exact-byte comparison; coefficient decode and metadata assembly excluded",
                            "trials": 7, "fixtures": rows]
print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
