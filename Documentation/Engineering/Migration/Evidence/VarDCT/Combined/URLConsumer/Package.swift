// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "ContractConsumer",
    platforms: [.macOS("26.0")],
    dependencies: [.package(url: "https://github.com/raster-labs/SwiftJXL.git", revision: "cd60774f3f8aab162aa3a0cb8bc28483745de35a")],
    targets: [
        .executableTarget(
            name: "ContractConsumer",
            dependencies: [.product(name: "SwiftJXL", package: "SwiftJXL")]
        )
    ],
    swiftLanguageModes: [.v6]
)
