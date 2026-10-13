import Foundation
import Darwin
#if PREDECESSOR
import JXLSwift
#else
import SwiftJXLCore
#endif

func forward(_ source: Data) throws -> Data {
#if PREDECESSOR
    return try JXLEncoder().encodeLosslessJPEG(source).data
#else
    return try JPEGNativeTranscode.encode(source, policy: policy()).data
#endif
}
func reverse(_ source: Data) throws -> Data {
#if PREDECESSOR
    return try JXLDecoder().decodeLosslessJPEG(source)
#else
    return try JPEGNativeTranscode.reconstruct(source, policy: policy()).data
#endif
}
#if !PREDECESSOR
func policy() throws -> JPEGNativePolicy {
    try JPEGNativePolicy(compressed: 64*1024*1024, coefficients: 64*1024*1024,
        workspace: 512*1024*1024, memory: 1024*1024*1024, metadata: 8*1024*1024,
        dimension: 2048, pixels: 2048*2048, nesting: 32,
        deadline: .now.advanced(by: .seconds(120)))
}
#endif
func emit(_ row: [String: Any]) throws {
    print(String(decoding:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),as:UTF8.self))
}
let args = CommandLine.arguments
var stage = "input"
do {
    let jpeg = try Data(contentsOf:URL(fileURLWithPath:args[2]))
    if args[1] == "preflight" {
        stage = "forward"
        let encoded = try forward(jpeg)
        try encoded.write(to:URL(fileURLWithPath:args[3]))
        stage = "reverse"
        let restored = try reverse(encoded)
        try emit(["stage":"complete", "exact":restored == jpeg,"inputBytes":jpeg.count,"outputBytes":encoded.count])
    } else {
        let encoded = try Data(contentsOf:URL(fileURLWithPath:args[3]))
        let isForward = args[1] == "forward"
        let expected = isForward ? encoded : jpeg
        func operation() throws -> Data { try isForward ? forward(jpeg) : reverse(encoded) }
        stage = args[1]
        for _ in 0..<5 {
            guard try operation() == expected else { throw NSError(domain:"byte mismatch",code:1) }
        }
        var samples: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            let output = try operation()
            let elapsed = start.duration(to:.now).components
            samples.append(Double(elapsed.seconds)*1e6 + Double(elapsed.attoseconds)/1e12)
            guard output == expected else { throw NSError(domain:"byte mismatch",code:2) }
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF,&usage) == 0 else { throw NSError(domain:"rusage",code:1) }
        try emit(["direction":args[1],"warmups":5,"samplesMicroseconds":samples,"inputBytes":jpeg.count,"outputBytes":encoded.count,"processHighWaterRSSBytes":usage.ru_maxrss])
    }
} catch {
    try emit(["stage":stage,"error":String(describing:error)])
    exit(1)
}
