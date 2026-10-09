// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0
import PackageDescription
let package = Package(name: "CLIValidationFixtures", platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "CLIValidationFixtures",
        dependencies: [.product(name: "SwiftJXL", package: "SwiftJXL")])],
    swiftLanguageModes: [.v6])
