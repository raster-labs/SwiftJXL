import Foundation
import Darwin
let name = CommandLine.arguments[1]
let folder = ["quant16", "multigroup-420", "rgb", "rgb-progressive"].contains(name) ? "JPEGBridge" : "JPEG"
let base = name == "icc-rgb" ? "444" : name == "icc-gray" ? "gray" : name
var source = try Data(contentsOf: URL(fileURLWithPath: "Tests/SwiftJXLCoreTests/Fixtures/\(folder)/\(base).jpg"))
if name.hasPrefix("icc-") {
    let profileName = name == "icc-gray" ? "gray-gamma22" : "srgb"
    let profile = try Data(contentsOf: URL(fileURLWithPath: "Tests/SwiftJXLCoreTests/Fixtures/JPEGBridge/\(profileName).icc"))
    let payload = Data("ICC_PROFILE\0".utf8) + Data([1,1]) + profile
    let size = payload.count + 2
    source.insert(contentsOf: Data([0xff,0xe2,UInt8(size >> 8),UInt8(size & 255)]) + payload, at: 2)
}
func policy() throws -> JPEGNativePolicy {
    try JPEGNativePolicy(compressed: 64*1024*1024, coefficients: 64*1024*1024,
        workspace: 512*1024*1024, memory: 1024*1024*1024, metadata: 8*1024*1024,
        dimension: 2048, pixels: 2048*2048, nesting: 32, deadline: .now.advanced(by: .seconds(120)))
}
let reference = try JPEGNativeTranscode.encode(source, policy: policy())
let iterations = name == "multigroup-420" ? 3 : 20
var rows: [[String: Any]] = []
for forward in [true, false] {
    func operation() throws -> JPEGNativeResult {
        if forward { return try JPEGNativeTranscode.encode(source, policy: policy()) }
        return try JPEGNativeTranscode.reconstruct(reference.data, policy: policy())
    }
    let expected = forward ? reference.data : source
    for _ in 0..<3 { guard try operation().data == expected else { throw JPEGEntropyError.malformed } }
    var samples: [Double] = []
    var knownCopyBytes = 0
    for _ in 0..<7 {
        let start = ContinuousClock.now
        for _ in 0..<iterations {
            let result = try operation()
            guard result.data == expected else { throw JPEGEntropyError.malformed }
            knownCopyBytes = result.containerCopyBytes
        }
        let elapsed = start.duration(to: .now).components
        samples.append((Double(elapsed.seconds)*1e6 + Double(elapsed.attoseconds)/1e12)/Double(iterations))
    }
    rows.append(["direction":forward ? "forward" : "reverse", "medianMicroseconds":samples.sorted()[3],
        "samplesMicroseconds":samples, "knownContainerCopyBytesPerOperation":knownCopyBytes])
}
var usage = rusage(); guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw JPEGEntropyError.malformed }
let report: [String: Any] = ["fixture":name, "sourceJPEGBytes":source.count, "nativeJXLBytes":reference.data.count,
    "warmups":3, "trials":7, "iterationsPerTrial":iterations, "operations":rows,
    "processHighWaterRSSBytes":usage.ru_maxrss,
    "scope":"Optimised native whole-operation core with output equality checks; includes metadata and output assembly. RSS is macOS process high-water including runtime, fixture setup and both directions; it is not per-call allocation or peak workspace. Known copy bytes cover container assembly only, not all allocations or metadata/entropy copies."]
print(String(decoding:try JSONSerialization.data(withJSONObject:report, options:[.sortedKeys,.prettyPrinted]),as:UTF8.self))
