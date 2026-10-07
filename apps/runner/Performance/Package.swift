// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "ACIRunnerPerformance",
  platforms: [
    .macOS(.v13)
  ],
  dependencies: [
    .package(path: ".."),
    .package(url: "https://github.com/ordo-one/benchmark", exact: "1.36.2")
  ],
  targets: [
    .executableTarget(
      name: "ACIRunnerBenchmarks",
      dependencies: [
        .product(name: "ACIRunnerCore", package: "runner"),
        .product(name: "Benchmark", package: "benchmark")
      ],
      path: "Benchmarks/ACIRunnerBenchmarks",
      plugins: [
        .plugin(name: "BenchmarkPlugin", package: "benchmark")
      ]
    )
  ]
)
