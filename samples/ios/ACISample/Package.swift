// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ACISample",
  platforms: [
    .iOS(.v16)
  ],
  products: [
    .library(name: "ACISample", targets: ["ACISample"])
  ],
  targets: [
    .target(name: "ACISample"),
    .testTarget(name: "ACISampleTests", dependencies: ["ACISample"]),
  ]
)
