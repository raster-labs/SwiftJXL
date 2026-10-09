// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "MemoryProbe", platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "MemoryProbe", dependencies: [.product(name: "SwiftJXL", package: "SwiftJXL")])],
    swiftLanguageModes: [.v6])
