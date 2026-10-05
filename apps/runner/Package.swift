// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "runner",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "aci-runner", targets: ["runner"])
    ],
    targets: [
        .executableTarget(name: "runner")
    ]
)
