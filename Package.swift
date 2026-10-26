// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlackoutChecks",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BlackoutCore", path: "Sources/Core"),
        .testTarget(name: "BlackoutCoreTests", dependencies: ["BlackoutCore"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
