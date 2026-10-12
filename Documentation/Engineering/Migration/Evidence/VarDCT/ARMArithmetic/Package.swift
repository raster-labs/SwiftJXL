// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ARMBiasDiagnostic", platforms: [.macOS("26.0")], targets: [.target(name: "SwiftJXLCore"), .executableTarget(name: "BiasProbe", dependencies: ["SwiftJXLCore"])], swiftLanguageModes: [.v6])
