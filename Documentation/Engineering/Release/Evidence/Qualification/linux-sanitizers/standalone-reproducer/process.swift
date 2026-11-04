import Foundation
for _ in 0..<100 {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/true")
    try child.run()
    child.waitUntilExit()
    precondition(child.terminationStatus == 0)
}
print("process-completed")
