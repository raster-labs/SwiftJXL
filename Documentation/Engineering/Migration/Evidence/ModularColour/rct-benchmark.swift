import Foundation
import Darwin
@main struct Benchmark {
    static func main() throws {
        let count = 65536
        var a = (0..<count).map { Int32(($0 * 71) & 65535) }
        var b = (0..<count).map { Int32(($0 * 113) & 65535) }
        var c = (0..<count).map { Int32(($0 * 37) & 65535) }
        let types: [UInt32] = [6,13,35,41]
        func cycle() throws {
            for type in types {
                #if BASELINE
                try SpecRCT.inverse(rctType:type,channel0:&a,channel1:&b,channel2:&c)
                #else
                try SpecRCT.inverse(rctType:type,channel0:&a,channel1:&b,channel2:&c,checkpoint:{ try Task.checkCancellation() })
                #endif
            }
        }
        for _ in 0..<3 { try cycle() }
        var samples: [Double] = []
        for _ in 0..<7 {
            let start = ContinuousClock.now
            for _ in 0..<10 { try cycle() }
            let d = start.duration(to:.now).components
            samples.append((Double(d.seconds)*1e6+Double(d.attoseconds)/1e12)/40)
        }
        let checksums = [a,b,c].map { $0.reduce(Int64(0)) { $0 + Int64($1) } }
        var usage = rusage(); guard getrusage(RUSAGE_SELF,&usage)==0 else { throw CancellationError() }
        let result: [String:Any] = ["samplesPerChannel":count,"types":types,"warmupCycles":3,"trials":7,"cyclesPerTrial":10,
            "microsecondsPerInverse":samples,"medianMicroseconds":samples.sorted()[3],"checksums":checksums,
            "processHighWaterRSSBytes":usage.ru_maxrss,
            "scope":"Repeated transform kernel on three unique synthetic signed32 working planes; excludes entropy, image IO and public API. Process high-water RSS includes runtime/setup and is not per-call allocation telemetry."]
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    }
}
