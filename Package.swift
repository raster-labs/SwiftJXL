// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "SwiftJXL",
    platforms: [
        .macOS("26.0"), .iOS("26.0"), .tvOS("26.0"),
        .visionOS("26.0"), .watchOS("26.0")
    ],
    products: [.library(name: "SwiftJXL", targets: ["SwiftJXL"]),
               .executable(name: "swiftjxl-cli", targets: ["SwiftJXLCLI"])],
    targets: [
        .target(name: "SwiftJXL"),
        .executableTarget(name: "SwiftJXLCLI", dependencies: ["SwiftJXL"]),
        .testTarget(name: "SwiftJXLTests", dependencies: ["SwiftJXL"])
    ],
    swiftLanguageModes: [.v6]
)
