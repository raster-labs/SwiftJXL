import Foundation
import JXLSwift
@main struct Probe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, let channels = Int(args[2]), let bits = Int(args[3]) else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        do {
            let frame = try await JXLDecoder().decode(data)
            let maximum = (1 << bits)-1
            var exact = frame.width == 513 && frame.height == 3 && frame.channels == channels
                && frame.data.count == 513 * 3 * channels
            if exact {
                for i in 0..<(513 * 3) { for c in 0..<channels {
                    if Int(frame.data[i * channels + c]) != (i * 71 + (i / 513) * 37 + c * 113) & maximum { exact = false }
                } }
            }
            print(exact ? "exact" : "mismatch")
        } catch { print("rejected: \(error)") }
    }
}
