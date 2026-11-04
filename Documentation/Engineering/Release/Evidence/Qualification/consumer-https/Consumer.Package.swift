// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Consumer", platforms: [.macOS("26.0")],
  dependencies: [.package(url: "https://github.com/raster-labs/SwiftJXL.git", revision: "00f03ff288a7c8e0e2b82d2e71ec22622ede71ae")],
  targets: [.executableTarget(name: "Consumer", dependencies: [
    .product(name: "SwiftJXL", package: "swiftjxl")])], swiftLanguageModes: [.v6])
