// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "ACIRunner",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "aci-runner", targets: ["runner"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0")
  ],
  targets: [
    .target(
      name: "ACIRunnerCore",
      dependencies: [
        .product(name: "Subprocess", package: "swift-subprocess")
      ]
    ),
    .executableTarget(
      name: "runner",
      dependencies: [
        "ACIRunnerCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ]
    ),
    .testTarget(
      name: "ACIRunnerCoreTests",
      dependencies: ["ACIRunnerCore"]
    )
  ]
)
