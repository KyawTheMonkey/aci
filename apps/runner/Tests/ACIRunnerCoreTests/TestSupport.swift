import ACIRunnerCore
import Foundation

func makeStep(
  id: String = "test",
  name: String = "Test",
  executable: String = "/usr/bin/true",
  arguments: [String] = [],
  environment: [String: String] = [:],
  workingDirectory: String? = nil,
  timeoutSeconds: Int? = 10,
  continueOnError: Bool = false
) -> StepSpecification {
  StepSpecification(
    id: id,
    name: name,
    kind: .command,
    executable: executable,
    arguments: arguments,
    environment: environment,
    workingDirectory: workingDirectory,
    timeoutSeconds: timeoutSeconds,
    continueOnError: continueOnError
  )
}

func makeJob(
  version: Int = 1,
  jobID: UUID = UUID(),
  timeoutSeconds: Int = 60,
  cleanAfterExecution: Bool = true,
  repository: RepositorySpecification? = nil,
  steps: [StepSpecification] = [makeStep()],
  artifacts: [ArtifactSpecification] = []
) -> JobSpecification {
  JobSpecification(
    version: version,
    jobID: jobID,
    timeoutSeconds: timeoutSeconds,
    workspace: WorkspaceSpecification(cleanAfterExecution: cleanAfterExecution),
    repository: repository,
    steps: steps,
    artifacts: artifacts
  )
}

func makeRepository(
  cloneURL: URL = URL(string: "https://github.com/example/ios-app.git")!,
  commitSHA: String = String(repeating: "a", count: 40)
) -> RepositorySpecification {
  RepositorySpecification(cloneURL: cloneURL, commitSHA: commitSHA)
}

func makeTemporaryDirectory(named name: String = UUID().uuidString) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("aci-runner-tests", isDirectory: true)
    .appendingPathComponent(name, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// One scripted answer from ``ScriptedCommandExecutor``.
enum ScriptedResponse: Sendable {
  /// Return this result after optionally emitting stderr text and waiting.
  case result(CommandExecutionResult, stderr: String = "", delay: Duration = .zero)
  /// Throw this error instead of returning a result.
  case failure(CommandExecutionError)
}

/// A process backend that replays scripted responses and records every command.
actor ScriptedCommandExecutor: CommandExecuting {
  private var responses: [ScriptedResponse]
  private(set) var commands: [Command] = []
  private(set) var stepIDs: [String] = []

  init(responses: [ScriptedResponse]) {
    self.responses = responses
  }

  func execute(
    _ command: Command,
    stepID: String,
    timeoutSeconds: Int,
    onLog: @escaping LogHandler
  ) async throws -> CommandExecutionResult {
    commands.append(command)
    stepIDs.append(stepID)

    guard !responses.isEmpty else {
      throw CommandExecutionError.launchFailed(
        executable: command.executableURL.path,
        reason: "No scripted response remains."
      )
    }

    switch responses.removeFirst() {
    case let .result(result, stderr, delay):
      if !stderr.isEmpty {
        await onLog(
          LogEvent(sequence: 0, stepID: stepID, stream: .stderr, timestamp: Date(), text: stderr)
        )
      }
      if delay > .zero {
        try await Task.sleep(for: delay)
      }
      return result
    case let .failure(error):
      throw error
    }
  }
}

func makeCommandResult(
  outcome: CommandOutcome,
  exitCode: Int32
) -> CommandExecutionResult {
  let now = Date()
  return CommandExecutionResult(
    outcome: outcome,
    exitCode: exitCode,
    terminationReason: outcome == .succeeded || outcome == .failed ? .exit : .uncaughtSignal,
    startedAt: now,
    finishedAt: now
  )
}
