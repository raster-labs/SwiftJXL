// swift-tools-version: 6.2
// Diagnostic qualification package: copied runtime and selected unchanged tests.
import PackageDescription
let package = Package(name: "SwiftJXL", platforms: [.macOS("26.0"), .iOS("26.0"), .tvOS("26.0"), .visionOS("26.0"), .watchOS("26.0")], products: [.library(name: "SwiftJXL", targets: ["SwiftJXL"])], targets: [.target(name: "SwiftJXL", dependencies: ["SwiftJXLCore"]), .target(name: "SwiftJXLCore"), .testTarget(name: "SwiftJXLCoreTests", dependencies: ["SwiftJXLCore", "SwiftJXL"], resources: [.copy("Fixtures/Modular")])], swiftLanguageModes: [.v6])
