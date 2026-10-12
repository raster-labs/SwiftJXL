import Foundation
import JXLSwift
@main struct Probe {
    static func main() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        do {
            let frame = try await JXLDecoder().decode(data)
            print("width=\(frame.width) height=\(frame.height) channels=\(frame.channels) iccBytes=\(frame.iccProfile?.count ?? 0)")
        } catch { print("rejected: \(error)") }
    }
}
