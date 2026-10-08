import ACIRunnerCore
import ArgumentParser
import Darwin
import Dispatch
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

/// Process exit statuses that let scripts and supervisors tell outcomes apart.
///
/// Values follow established conventions: `sysexits(3)` for data and software
/// errors, `timeout(1)` for deadlines, and the shell's `128 + SIGINT` for
/// interruption.
enum RunnerExitStatus {
  static let failed: Int32 = 1
  static let invalidJob: Int32 = 65
  static let infrastructureFailed: Int32 = 70
  static let timedOut: Int32 = 124
  static let cancelled: Int32 = 130

  static func status(for outcome: ExecutionOutcome) -> Int32? {
    switch outcome {
    case .succeeded: nil
    case .failed: failed
    case .timedOut: timedOut
    case .cancelled: cancelled
    case .infrastructureFailed: infrastructureFailed
    }
  }
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

  @Option(
    name: .long,
    help: "Workspace root whose volume is measured for available disk space."
  )
  var workspaceRoot: String?

  func run() async throws {
    let capabilities = await CapabilityDetector(
      storageURL: resolveWorkspaceRoot(workspaceRoot)
    ).detect()
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
    abstract: "Execute a normalized ACI job from a local JSON file.",
    discussion: """
      Exit status is 0 on success, 1 for a failed step, 65 for an invalid job, \
      70 for a runner infrastructure failure, 124 for a timeout, and 130 when \
      the job was cancelled by SIGINT or SIGTERM.
      """
  )

  @Option(name: [.short, .long], help: "Path to the normalized job JSON file.")
  var job: String

  @Option(
    name: .long,
    help: "Directory under which isolated job workspaces are created."
  )
  var workspaceRoot: String?

  @Option(name: .long, help: "Write the job result as JSON to this path.")
  var result: String?

  @Flag(
    name: .long,
    help: "Allow file:// repository URLs for offline local acceptance testing."
  )
  var allowLocalRepository = false

  func run() async throws {
    // A closed log pipe must not kill the runner mid-job. With a handler
    // installed, writes report EPIPE and the job continues without that sink.
    // A handler, unlike SIG_IGN, is reset to the default in spawned steps.
    installNoOpSignalHandler(SIGPIPE)

    let specification: JobSpecification
    do {
      let specificationURL = URL(fileURLWithPath: job).standardizedFileURL
      let data = try Data(contentsOf: specificationURL)
      specification = try JSONDecoder().decode(JobSpecification.self, from: data)
    } catch {
      throw exit(RunnerExitStatus.invalidJob, "Unable to read the job specification: \(error.localizedDescription)")
    }

    let workspaceManager = try WorkspaceManager(baseDirectory: resolveWorkspaceRoot(workspaceRoot))
    let validationLimits = JobSpecificationValidationLimits(
      allowsFileRepositoryURLs: allowLocalRepository
    )
    let executor = JobExecutor(
      validator: JobSpecificationValidator(limits: validationLimits),
      workspaceManager: workspaceManager
    )

    let execution = Task {
      try await executor.execute(specification) { event in
        let handle = event.stream == .stdout
          ? FileHandle.standardOutput
          : FileHandle.standardError
        try? handle.write(contentsOf: Data(event.text.utf8))
      }
    }

    // Steps run in their own session and never see the terminal's signals.
    // Cancelling the job task is the only path that tears down the process
    // group and removes the workspace, so SIGINT and SIGTERM must route there.
    let signals = SignalMonitor(signals: [SIGINT, SIGTERM]) {
      execution.cancel()
    }
    defer { signals.cancel() }

    let jobResult: JobResult
    do {
      jobResult = try await execution.value
    } catch let error as JobSpecificationError {
      throw exit(RunnerExitStatus.invalidJob, "Invalid job specification: \(error.localizedDescription)")
    } catch {
      throw exit(RunnerExitStatus.infrastructureFailed, "Runner could not start the job: \(error.localizedDescription)")
    }

    printSummary(jobResult)
    if let result {
      try writeResult(jobResult, to: result)
    }

    if let status = RunnerExitStatus.status(for: jobResult.outcome) {
      throw ExitCode(status)
    }
  }

  private func printSummary(_ result: JobResult) {
    print("\nJob \(result.jobID.uuidString.lowercased()): \(result.outcome.rawValue)")
    for step in result.stepResults {
      let exitDescription: String
      switch (step.exitCode, step.terminationReason) {
      case let (code?, .uncaughtSignal?):
        exitDescription = " signal=\(code)"
      case let (code?, _):
        exitDescription = " exit=\(code)"
      case (nil, _):
        exitDescription = ""
      }
      print("- \(step.stepID): \(step.outcome.rawValue)\(exitDescription)")
    }

    if let failureReason = result.failureReason {
      print("Reason: \(failureReason)")
    }

    for warning in result.warnings {
      print("Warning: \(warning)")
    }
  }

  private func writeResult(_ result: JobResult, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
    try encoder.encode(result).write(to: url, options: .atomic)
  }

  /// Reports a message on stderr and returns the exit code to throw.
  private func exit(_ status: Int32, _ message: String) -> ExitCode {
    try? FileHandle.standardError.write(contentsOf: Data("Error: \(message)\n".utf8))
    return ExitCode(status)
  }
}

/// Resolves the workspace root option or the default location.
///
/// The default lives in the user's caches and carries a `.noindex` suffix so
/// Spotlight does not index derived data and simulator output, which measurably
/// slows Xcode builds.
func resolveWorkspaceRoot(_ option: String?) -> URL {
  if let option {
    let expanded = NSString(string: option).expandingTildeInPath
    return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
  }

  return FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Caches", isDirectory: true)
    .appendingPathComponent("ACI", isDirectory: true)
    .appendingPathComponent("Runner", isDirectory: true)
    .appendingPathComponent("workspaces.noindex", isDirectory: true)
}

/// Replaces a signal's default action with a handler that does nothing.
///
/// Dispatch signal sources require the default action to be disabled. A no-op
/// handler is used instead of `SIG_IGN` because ignored dispositions survive
/// `exec` and would be inherited by every step process.
private func installNoOpSignalHandler(_ signalNumber: Int32) {
  signal(signalNumber) { _ in }
}

/// Invokes a handler on a background queue when any monitored signal arrives.
private final class SignalMonitor: @unchecked Sendable {
  private let sources: [DispatchSourceSignal]

  init(signals: [Int32], handler: @escaping @Sendable () -> Void) {
    sources = signals.map { signalNumber in
      installNoOpSignalHandler(signalNumber)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
      source.setEventHandler(handler: handler)
      source.activate()
      return source
    }
  }

  func cancel() {
    for source in sources {
      source.cancel()
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
