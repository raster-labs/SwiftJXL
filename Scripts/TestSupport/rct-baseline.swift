// SPDX-License-Identifier: Apache-2.0
import Foundation
@main struct RCTVectors {
    static func main() throws {
        let inputs: [[Int32]] = [
            [0,1,-1,32767,-32768,65535,Int32.min,Int32.max, 127],
            [1,-1,0,-32768,32767,65535,Int32.max,Int32.min,-255],
            [-1,0,1,65535,-32768,32767,Int32.min,Int32.max,511]
        ]
        var cases: [[String:Any]] = []
        for type in UInt32(0)..<42 {
            var a=inputs[0],b=inputs[1],c=inputs[2]
            #if BASELINE
            try SpecRCT.inverse(rctType:type,channel0:&a,channel1:&b,channel2:&c)
            #else
            try SpecRCT.inverse(rctType:type,channel0:&a,channel1:&b,channel2:&c,checkpoint:{})
            #endif
            cases.append(["type":type,"output":[a,b,c]])
        }
        let result:[String:Any] = ["input":inputs,"cases":cases]
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
    }
}
