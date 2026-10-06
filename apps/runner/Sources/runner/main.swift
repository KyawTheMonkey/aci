import ACIRunnerCore
import ArgumentParser
import Foundation

/// The root command for local ACI runner operations.
@main
struct ACICommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "aci-runner",
    abstract: "Execute ACI jobs on this Mac.",
    version: ACIRunnerVersion.current,
    subcommands: [
      VersionCommand.self,
      CapabilitiesCommand.self,
      ExecuteCommand.self,
    ]
  )
}

/// Prints human-readable runner and protocol version information.
struct VersionCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "version",
    abstract: "Print the runner and protocol versions."
  )

  func run() {
    print("aci-runner \(ACIRunnerVersion.current) (protocol \(ACIRunnerVersion.protocolVersion))")
  }
}

/// Emits a machine-readable report used by the future scheduler.
struct CapabilitiesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "capabilities",
    abstract: "Inspect this Mac and print runner capabilities as JSON."
  )

  func run() async throws {
    let capabilities = await CapabilityDetector().detect()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(capabilities)

    guard let json = String(data: data, encoding: .utf8) else {
      throw RunnerCLIError.unableToEncodeCapabilities
    }

    print(json)
  }
}

/// Decodes and executes a normalized job from the local filesystem.
///
/// This command is the local execution entry point. A later service command
/// will obtain the same specification from the control plane and reuse
/// `JobExecutor`.
struct ExecuteCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "execute",
    abstract: "Execute a normalized ACI job from a local JSON file."
  )

  @Option(name: [.short, .long], help: "Path to the normalized job JSON file.")
  var job: String

  @Option(
    name: .long,
    help: "Directory under which isolated job workspaces are created."
  )
  var workspaceRoot: String?

  @Flag(
    name: .long,
    help: "Allow file:// repository URLs for offline local acceptance testing."
  )
  var allowLocalRepository = false

  func run() async throws {
    let specificationURL = URL(fileURLWithPath: job).standardizedFileURL
    let data = try Data(contentsOf: specificationURL)
    let specification = try JSONDecoder().decode(JobSpecification.self, from: data)
    let workspaceBase = resolvedWorkspaceRoot()
    let workspaceManager = try WorkspaceManager(baseDirectory: workspaceBase)
    let validationLimits = JobSpecificationValidationLimits(
      allowsFileRepositoryURLs: allowLocalRepository
    )
    let executor = JobExecutor(
      validator: JobSpecificationValidator(limits: validationLimits),
      workspaceManager: workspaceManager
    )

    let result = try await executor.execute(specification) { event in
      let handle = event.stream == .stdout
        ? FileHandle.standardOutput
        : FileHandle.standardError
      handle.write(Data(event.text.utf8))
    }

    printSummary(result)

    if result.outcome != .succeeded {
      throw ExitCode.failure
    }
  }

  private func resolvedWorkspaceRoot() -> URL {
    if let workspaceRoot {
      let expanded = NSString(string: workspaceRoot).expandingTildeInPath
      return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("ACI", isDirectory: true)
      .appendingPathComponent("Runner", isDirectory: true)
      .appendingPathComponent("workspaces", isDirectory: true)
  }

  private func printSummary(_ result: JobResult) {
    print("\nJob \(result.jobID.uuidString.lowercased()): \(result.outcome.rawValue)")
    for step in result.stepResults {
      let exitDescription = step.exitCode.map { " exit=\($0)" } ?? ""
      print("- \(step.stepID): \(step.outcome.rawValue)\(exitDescription)")
    }

    if let failureReason = result.failureReason {
      print("Reason: \(failureReason)")
    }
  }
}

enum RunnerCLIError: LocalizedError {
  case unableToEncodeCapabilities

  var errorDescription: String? {
    switch self {
    case .unableToEncodeCapabilities:
      "Runner capabilities could not be encoded as UTF-8 JSON."
    }
  }
}
