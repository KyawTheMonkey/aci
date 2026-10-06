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
  steps: [StepSpecification] = [makeStep()],
  artifacts: [ArtifactSpecification] = []
) -> JobSpecification {
  JobSpecification(
    version: version,
    jobID: jobID,
    timeoutSeconds: timeoutSeconds,
    workspace: WorkspaceSpecification(cleanAfterExecution: cleanAfterExecution),
    steps: steps,
    artifacts: artifacts
  )
}

func makeTemporaryDirectory(named name: String = UUID().uuidString) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("aci-runner-tests", isDirectory: true)
    .appendingPathComponent(name, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
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
