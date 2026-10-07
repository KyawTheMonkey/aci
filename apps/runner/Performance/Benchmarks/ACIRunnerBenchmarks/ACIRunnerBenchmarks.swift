import ACIRunnerCore
import Benchmark
import Foundation

/// Performance probes for work the ACI runner itself owns.
///
/// These deliberately avoid `xcodebuild`: compiler and simulator performance
/// belongs in the end-to-end workload, while this suite isolates contract
/// decoding, validation, orchestration, process launch, and log draining.
let benchmarks: @Sendable () -> Void = {
  let fixtures = BenchmarkFixtures()

  let coreLatency = BenchmarkThresholds(
    relative: [.p50: 10, .p90: 15]
  )
  let coreAllocationCount = BenchmarkThresholds(
    relative: [.p50: 10, .p90: 15]
  )
  let orchestrationLatency = BenchmarkThresholds(
    relative: [.p50: 15, .p90: 20]
  )
  let operatingSystemLatency = BenchmarkThresholds(
    relative: [.p50: 50, .p90: 60]
  )

  let coreConfiguration = Benchmark.Configuration(
    metrics: [
      .wallClock,
      .throughput,
      .mallocCountTotal,
      .mallocBytesCount,
    ],
    warmupIterations: 3,
    scalingFactor: .kilo,
    maxDuration: .seconds(2),
    maxIterations: 10_000,
    thresholds: [
      .wallClock: coreLatency,
      .throughput: coreLatency,
      .mallocCountTotal: coreAllocationCount,
      .mallocBytesCount: .none,
    ]
  )

  Benchmark("Job specification: decode one-step JSON", configuration: coreConfiguration) {
    benchmark in
    for _ in benchmark.scaledIterations {
      let specification = try JSONDecoder().decode(
        JobSpecification.self,
        from: fixtures.oneStepJSON
      )
      blackHole(specification)
    }
  }

  var maximumDecodeConfiguration = coreConfiguration
  maximumDecodeConfiguration.scalingFactor = .one
  maximumDecodeConfiguration.maxDuration = .seconds(3)

  Benchmark(
    "Job specification: decode 100-step JSON",
    configuration: maximumDecodeConfiguration
  ) { _ in
    let specification = try JSONDecoder().decode(
      JobSpecification.self,
      from: fixtures.maximumJSON
    )
    blackHole(specification)
  }

  Benchmark("Job validation: one step", configuration: coreConfiguration) { benchmark in
    let validator = JobSpecificationValidator()
    for _ in benchmark.scaledIterations {
      try validator.validate(fixtures.oneStepSpecification)
    }
  }

  var maximumValidationConfiguration = coreConfiguration
  maximumValidationConfiguration.scalingFactor = .one
  maximumValidationConfiguration.maxDuration = .seconds(3)

  Benchmark(
    "Job validation: 100 steps and 100 artifacts",
    configuration: maximumValidationConfiguration
  ) { _ in
    try JobSpecificationValidator().validate(fixtures.maximumSpecification)
  }

  let orchestrationConfiguration = Benchmark.Configuration(
    metrics: [
      .wallClock,
      .throughput,
      .mallocCountTotal,
      .mallocBytesCount,
      .peakMemoryResidentDelta,
    ],
    warmupIterations: 3,
    maxDuration: .seconds(3),
    maxIterations: 1_000,
    thresholds: [
      .wallClock: orchestrationLatency,
      .throughput: orchestrationLatency,
      .mallocCountTotal: coreAllocationCount,
      .mallocBytesCount: .none,
      .peakMemoryResidentDelta: .none,
    ]
  )

  Benchmark(
    "Job orchestration: 100 successful steps without processes",
    configuration: orchestrationConfiguration
  ) { _ in
    let executor = JobExecutor(
      workspaceManager: BenchmarkWorkspaceManager(rootURL: fixtures.workingDirectory),
      commandExecutor: SuccessfulCommandExecutor()
    )
    let result = try await executor.execute(fixtures.maximumSpecification)
    precondition(result.stepResults.count == 100)
    blackHole(result)
  }

  let processConfiguration = Benchmark.Configuration(
    metrics: [
      .wallClock,
      .cpuTotal,
      .throughput,
      .peakMemoryResidentDelta,
      .syscalls,
      .contextSwitches,
    ],
    warmupIterations: 3,
    maxDuration: .seconds(4),
    maxIterations: 1_000,
    thresholds: [
      .wallClock: operatingSystemLatency,
      .throughput: operatingSystemLatency,
      .cpuTotal: .none,
      .peakMemoryResidentDelta: .none,
      .syscalls: .none,
      .contextSwitches: .none,
    ]
  )

  Benchmark(
    "Command execution: launch /usr/bin/true",
    configuration: processConfiguration
  ) { _ in
    let result = try await CommandExecutor(terminationGracePeriod: .milliseconds(100)).execute(
      fixtures.trueCommand,
      stepID: "benchmark-true",
      timeoutSeconds: 10,
      onLog: { _ in }
    )
    precondition(result.outcome == .succeeded)
    blackHole(result)
  }

  var logConfiguration = processConfiguration
  logConfiguration.maxDuration = .seconds(5)
  logConfiguration.maxIterations = 100

  Benchmark(
    "Command execution: drain 1 MiB stdout",
    configuration: logConfiguration
  ) { _ in
    let result = try await CommandExecutor(terminationGracePeriod: .milliseconds(100)).execute(
      fixtures.oneMiBOutputCommand,
      stepID: "benchmark-output",
      timeoutSeconds: 10,
      onLog: { event in
        blackHole(event.text.utf8.count)
      }
    )
    precondition(result.outcome == .succeeded)
    blackHole(result)
  }
}

private struct BenchmarkFixtures: Sendable {
  let oneStepSpecification: JobSpecification
  let maximumSpecification: JobSpecification
  let oneStepJSON: Data
  let maximumJSON: Data
  let workingDirectory: URL
  let trueCommand: Command
  let oneMiBOutputCommand: Command

  init() {
    let oneStep = Self.makeStep(index: 0)
    oneStepSpecification = JobSpecification(
      version: 1,
      jobID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      timeoutSeconds: 3_600,
      workspace: WorkspaceSpecification(cleanAfterExecution: true),
      steps: [oneStep],
      artifacts: []
    )

    maximumSpecification = JobSpecification(
      version: 1,
      jobID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      timeoutSeconds: 3_600,
      workspace: WorkspaceSpecification(cleanAfterExecution: true),
      steps: (0..<100).map(Self.makeStep),
      artifacts: (0..<100).map { index in
        ArtifactSpecification(
          path: "artifacts/output-\(index).xcresult",
          required: index.isMultiple(of: 2)
        )
      }
    )

    let encoder = JSONEncoder()
    oneStepJSON = try! encoder.encode(oneStepSpecification)
    maximumJSON = try! encoder.encode(maximumSpecification)

    workingDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
    let environment = ProcessInfo.processInfo.environment
    trueCommand = Command(
      executableURL: URL(fileURLWithPath: "/usr/bin/true"),
      arguments: [],
      environment: environment,
      workingDirectoryURL: workingDirectory
    )
    oneMiBOutputCommand = Command(
      executableURL: URL(fileURLWithPath: "/bin/dd"),
      arguments: ["if=/dev/zero", "bs=1048576", "count=1"],
      environment: environment,
      workingDirectoryURL: workingDirectory
    )
  }

  private static func makeStep(index: Int) -> StepSpecification {
    StepSpecification(
      id: "step-\(index)",
      name: "Benchmark step \(index)",
      kind: .command,
      executable: "/usr/bin/true",
      arguments: ["--benchmark", "\(index)"],
      environment: [
        "ACI_BENCHMARK_INDEX": "\(index)",
        "ACI_BENCHMARK_MODE": "performance",
      ],
      workingDirectory: "build/step-\(index)",
      timeoutSeconds: 60,
      continueOnError: false
    )
  }
}

private struct BenchmarkWorkspaceManager: WorkspaceManaging, Sendable {
  let rootURL: URL

  func createWorkspace(for jobID: UUID) throws -> Workspace {
    Workspace(rootURL: rootURL.appendingPathComponent(jobID.uuidString, isDirectory: true))
  }

  func resolve(_ relativePath: String, in workspace: Workspace) throws -> URL {
    workspace.rootURL.appendingPathComponent(relativePath).standardizedFileURL
  }

  func removeWorkspace(_ workspace: Workspace) throws {}
}

private struct SuccessfulCommandExecutor: CommandExecuting, Sendable {
  func execute(
    _ command: Command,
    stepID: String,
    timeoutSeconds: Int,
    onLog: @escaping LogHandler
  ) async throws -> CommandExecutionResult {
    let now = Date()
    return CommandExecutionResult(
      outcome: .succeeded,
      exitCode: 0,
      terminationReason: .exit,
      startedAt: now,
      finishedAt: now
    )
  }
}
