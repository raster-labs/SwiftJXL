// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Consumer", platforms: [.macOS("26.0")],
  dependencies: [.package(url: "file:///Users/pushparaj/Documents/ChatGPT/SwiftJXL-milestone5/.build/milestone5-consumer-versioned-ci-safe/work/SwiftJXL.git", exact: "2.1.0-dev.2")],
  targets: [.executableTarget(name: "Consumer", dependencies: [
    .product(name: "SwiftJXL", package: "swiftjxl")])], swiftLanguageModes: [.v6])
