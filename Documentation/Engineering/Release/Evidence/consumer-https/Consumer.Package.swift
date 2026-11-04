// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Consumer", platforms: [.macOS("26.0")],
  dependencies: [.package(url: "https://github.com/raster-labs/SwiftJXL.git", revision: "c449992dc25d601dd8743b872abeddc4df84bfe7")],
  targets: [.executableTarget(name: "Consumer", dependencies: [
    .product(name: "SwiftJXL", package: "swiftjxl")])], swiftLanguageModes: [.v6])
