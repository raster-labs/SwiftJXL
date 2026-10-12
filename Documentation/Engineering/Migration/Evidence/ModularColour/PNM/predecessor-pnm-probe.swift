import Foundation
import JXLSwift
@main struct Probe {
    static func main() async throws {
        let cases: [(String, Data)] = [
            ("standard-ppm", Data("P6\n1 1\n255\n".utf8) + Data([0,128,255])),
            ("unsupported-tuple", Data("P7\nWIDTH 1\nHEIGHT 1\nDEPTH 4\nMAXVAL 255\nTUPLTYPE CMYK\nENDHDR\n".utf8) + Data([0,1,2,3])),
            ("standard-comment", Data("P5\n# comment\n1 1\n255\n".utf8) + Data([10]))
        ]
        var report: [[String: Any]] = []
        for (name, input) in cases {
            do {
                let frame = try PNM.read(input)
                var item: [String: Any] = ["case":name, "accepted":true,"colour":String(describing:frame.colorSpace),"alphaChannels":frame.alphaChannels]
                if name == "standard-ppm" {
                    let encoded = try await JXLEncoder(options: .init(mode: .lossless, effort: .falcon, containerWrap: false)).encode(frame)
                    try encoded.data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
                    item["output"] = CommandLine.arguments[1]
                }
                report.append(item)
            } catch { report.append(["case":name,"accepted":false,"error":String(describing:error)]) }
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report, options:[.prettyPrinted,.sortedKeys]))
    }
}
