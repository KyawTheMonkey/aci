import Foundation
import os

/// Validates and executes all steps in a normalized job sequentially.
///
/// The executor owns orchestration rather than low-level process behavior. It
/// creates the workspace, resolves step commands, enforces the overall job
/// deadline, classifies failures, and guarantees configured cleanup.
public struct JobExecutor: Sendable {
  private let validator: JobSpecificationValidator
  private let workspaceManager: any WorkspaceManaging
  private let commandExecutor: any CommandExecuting
  private let repositoryPreparer: any RepositoryPreparing
  private let environmentPolicy: ProcessEnvironmentPolicy

  /// Creates a job executor with injectable filesystem and process backends.
  ///
  /// Dependency injection keeps orchestration tests deterministic and avoids
  /// launching real processes for every job-state test.
  public init(
    validator: JobSpecificationValidator = .init(),
    workspaceManager: any WorkspaceManaging,
    commandExecutor: any CommandExecuting = CommandExecutor(),
    repositoryPreparer: (any RepositoryPreparing)? = nil,
    environmentPolicy: ProcessEnvironmentPolicy = .init()
  ) {
    self.validator = validator
    self.workspaceManager = workspaceManager
    self.commandExecutor = commandExecutor
    self.repositoryPreparer = repositoryPreparer
      ?? GitRepositoryPreparer(
        commandExecutor: commandExecutor,
        environmentPolicy: environmentPolicy
      )
    self.environmentPolicy = environmentPolicy
  }

  /// Executes a job while discarding its streamed log events.
  public func execute(_ specification: JobSpecification) async throws -> JobResult {
    try await execute(specification, onLog: { _ in })
  }

  /// Executes a job and forwards globally sequenced log events.
  /// - Parameters:
  ///   - specification: The decoded normalized job contract.
  ///   - onLog: An asynchronous consumer for job-wide log events.
  /// - Returns: A terminal result for every outcome once a workspace exists,
  ///   including failures discovered while a later step was being prepared.
  /// - Throws: A validation or workspace error that prevents execution from starting.
  public func execute(
    _ specification: JobSpecification,
    onLog: @escaping LogHandler
  ) async throws -> JobResult {
    try validator.validate(specification)

    let jobStartedAt = Date()
    let deadline = jobStartedAt.addingTimeInterval(TimeInterval(specification.timeoutSeconds))
    let workspace = try workspaceManager.createWorkspace(for: specification.jobID)
    let jobLogSequencer = JobLogSequencer(handler: onLog)

    let execution = await run(
      specification,
      in: workspace,
      deadline: deadline,
      logSequencer: jobLogSequencer
    )

    var warnings: [String] = []
    if specification.workspace.cleanAfterExecution {
      do {
        try workspaceManager.removeWorkspace(workspace)
      } catch {
        let warning = "Workspace '\(workspace.rootURL.path)' could not be removed: \(error.localizedDescription)"
        Logger(subsystem: "dev.aci.runner", category: "workspace")
          .error("\(warning, privacy: .public)")
        warnings.append(warning)
      }
    }

    return JobResult(
      jobID: specification.jobID,
      outcome: execution.outcome,
      stepResults: execution.stepResults,
      startedAt: jobStartedAt,
      finishedAt: Date(),
      failureReason: execution.failureReason,
      warnings: warnings
    )
  }

  /// Runs checkout and steps, converting every failure into a terminal result.
  private func run(
    _ specification: JobSpecification,
    in workspace: Workspace,
    deadline: Date,
    logSequencer: JobLogSequencer
  ) async -> Execution {
    var stepResults: [StepResult] = []

    let baseEnvironment: [String: String]
    do {
      baseEnvironment = try makeBaseEnvironment(for: specification, in: workspace)
    } catch {
      return Execution(
        outcome: .infrastructureFailed,
        stepResults: stepResults,
        failureReason: "Runner could not prepare the job environment: \(error.localizedDescription)"
      )
    }

    if let repository = specification.repository {
      let checkoutStartedAt = Date()

      do {
        try await repositoryPreparer.prepare(
          repository,
          in: workspace,
          deadline: deadline,
          onLog: { event in
            await logSequencer.forward(event)
          }
        )
        stepResults.append(
          StepResult(
            stepID: GitRepositoryPreparer.stepID,
            outcome: .succeeded,
            exitCode: nil,
            startedAt: checkoutStartedAt,
            finishedAt: Date(),
            failureReason: nil
          )
        )
      } catch let error as RepositoryPreparationError {
        let failure = repositoryFailure(from: error)
        stepResults.append(
          StepResult(
            stepID: GitRepositoryPreparer.stepID,
            outcome: failure.outcome,
            exitCode: failure.exitCode,
            terminationReason: failure.terminationReason,
            startedAt: checkoutStartedAt,
            finishedAt: Date(),
            failureReason: error.localizedDescription
          )
        )

        return Execution(
          outcome: failure.outcome,
          stepResults: stepResults,
          failureReason: "Repository checkout failed: \(error.localizedDescription)"
        )
      } catch is CancellationError {
        stepResults.append(
          StepResult(
            stepID: GitRepositoryPreparer.stepID,
            outcome: .cancelled,
            exitCode: nil,
            startedAt: checkoutStartedAt,
            finishedAt: Date(),
            failureReason: "Repository checkout was cancelled."
          )
        )

        return Execution(
          outcome: .cancelled,
          stepResults: stepResults,
          failureReason: "Repository checkout was cancelled."
        )
      } catch {
        stepResults.append(
          StepResult(
            stepID: GitRepositoryPreparer.stepID,
            outcome: .infrastructureFailed,
            exitCode: nil,
            startedAt: checkoutStartedAt,
            finishedAt: Date(),
            failureReason: error.localizedDescription
          )
        )

        return Execution(
          outcome: .infrastructureFailed,
          stepResults: stepResults,
          failureReason: "Runner could not prepare the repository: \(error.localizedDescription)"
        )
      }
    }

    for step in specification.steps {
      if Task.isCancelled {
        return Execution(
          outcome: .cancelled,
          stepResults: stepResults,
          failureReason: "Job execution was cancelled."
        )
      }

      let remainingJobSeconds = Int(ceil(deadline.timeIntervalSinceNow))
      guard remainingJobSeconds > 0 else {
        return Execution(
          outcome: .timedOut,
          stepResults: stepResults,
          failureReason: "Job timeout was reached before step '\(step.id)' started."
        )
      }

      let stepStartedAt = Date()

      // A previous step may have replaced a workspace path with a symbolic
      // link that points outside the workspace. That is a failure of this
      // step, not of the runner, and earlier step results must survive it.
      let workingDirectory: URL
      do {
        if let relativeDirectory = step.workingDirectory, relativeDirectory != "." {
          workingDirectory = try workspaceManager.resolve(relativeDirectory, in: workspace)
        } else {
          workingDirectory = workspace.rootURL
        }
      } catch {
        let reason = "Working directory could not be resolved: \(error.localizedDescription)"
        stepResults.append(
          StepResult(
            stepID: step.id,
            outcome: .failed,
            exitCode: nil,
            startedAt: stepStartedAt,
            finishedAt: Date(),
            failureReason: reason
          )
        )

        return Execution(
          outcome: .failed,
          stepResults: stepResults,
          failureReason: "Step '\(step.id)' failed: \(reason)"
        )
      }

      var environment = baseEnvironment
      environment.merge(step.environment) { _, stepValue in stepValue }

      let command = Command(
        executableURL: URL(fileURLWithPath: step.executable).standardizedFileURL,
        arguments: step.arguments,
        environment: environment,
        workingDirectoryURL: workingDirectory
      )
      // A step can request a shorter deadline but can never extend the time
      // remaining on the enclosing job.
      let effectiveTimeout = min(step.timeoutSeconds ?? remainingJobSeconds, remainingJobSeconds)

      do {
        let commandResult = try await commandExecutor.execute(
          command,
          stepID: step.id,
          timeoutSeconds: effectiveTimeout,
          onLog: { event in
            await logSequencer.forward(event)
          }
        )
        let outcome = executionOutcome(for: commandResult.outcome)
        let failureReason = failureReason(for: commandResult.outcome)
        let stepResult = StepResult(
          stepID: step.id,
          outcome: outcome,
          exitCode: commandResult.exitCode,
          terminationReason: commandResult.terminationReason,
          startedAt: commandResult.startedAt,
          finishedAt: commandResult.finishedAt,
          failureReason: failureReason
        )
        stepResults.append(stepResult)

        switch outcome {
        case .succeeded:
          continue
        case .failed where step.continueOnError:
          continue
        case .failed:
          return Execution(
            outcome: .failed,
            stepResults: stepResults,
            failureReason: "Step '\(step.id)' \(terminationDescription(for: commandResult))."
          )
        case .timedOut:
          return Execution(
            outcome: .timedOut,
            stepResults: stepResults,
            failureReason: "Step '\(step.id)' timed out."
          )
        case .cancelled:
          return Execution(
            outcome: .cancelled,
            stepResults: stepResults,
            failureReason: "Step '\(step.id)' was cancelled."
          )
        case .infrastructureFailed:
          assertionFailure("Command execution cannot directly return an infrastructure failure.")
        }
      } catch let error as CommandExecutionError where isUserLaunchFailure(error) {
        // The job named an executable or directory that does not exist on
        // this runner. Retrying elsewhere cannot fix a workflow mistake, so
        // this is a step failure rather than an infrastructure failure.
        stepResults.append(
          StepResult(
            stepID: step.id,
            outcome: .failed,
            exitCode: nil,
            startedAt: stepStartedAt,
            finishedAt: Date(),
            failureReason: error.localizedDescription
          )
        )

        if step.continueOnError {
          continue
        }

        return Execution(
          outcome: .failed,
          stepResults: stepResults,
          failureReason: "Step '\(step.id)' failed: \(error.localizedDescription)"
        )
      } catch {
        stepResults.append(
          StepResult(
            stepID: step.id,
            outcome: .infrastructureFailed,
            exitCode: nil,
            startedAt: stepStartedAt,
            finishedAt: Date(),
            failureReason: error.localizedDescription
          )
        )

        return Execution(
          outcome: .infrastructureFailed,
          stepResults: stepResults,
          failureReason: "Runner failed to execute step '\(step.id)': \(error.localizedDescription)"
        )
      }
    }

    return Execution(outcome: .succeeded, stepResults: stepResults, failureReason: nil)
  }

  /// Builds the environment shared by every step before step overrides apply.
  ///
  /// The job receives an allowlisted copy of the runner environment, the ACI
  /// job variables, and a `TMPDIR` inside the workspace so temporary files
  /// disappear with the job instead of accumulating in the user's temp folder.
  private func makeBaseEnvironment(
    for specification: JobSpecification,
    in workspace: Workspace
  ) throws -> [String: String] {
    let temporaryDirectory = workspace.rootURL
      .appendingPathComponent(".aci", isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )

    var environment = environmentPolicy.environment()
    environment[JobEnvironment.ci] = "true"
    environment[JobEnvironment.aci] = "true"
    environment[JobEnvironment.jobID] = specification.jobID.uuidString.lowercased()
    environment[JobEnvironment.workspace] = workspace.rootURL.path
    environment[JobEnvironment.temporaryDirectory] = temporaryDirectory.path
    environment["TMPDIR"] = temporaryDirectory.path
    if let repository = specification.repository {
      environment[JobEnvironment.commitSHA] = repository.commitSHA
    }
    return environment
  }

  private func isUserLaunchFailure(_ error: CommandExecutionError) -> Bool {
    switch error {
    case .executableUnavailable, .workingDirectoryUnavailable:
      true
    case .invalidTimeout, .launchFailed:
      false
    }
  }

  private func executionOutcome(for commandOutcome: CommandOutcome) -> ExecutionOutcome {
    switch commandOutcome {
    case .succeeded: .succeeded
    case .failed: .failed
    case .timedOut: .timedOut
    case .cancelled: .cancelled
    }
  }

  private func failureReason(for commandOutcome: CommandOutcome) -> String? {
    switch commandOutcome {
    case .succeeded: nil
    case .failed: "Command returned a nonzero exit code."
    case .timedOut: "Command timed out."
    case .cancelled: "Command was cancelled."
    }
  }

  private func terminationDescription(for result: CommandExecutionResult) -> String {
    switch result.terminationReason {
    case .exit: "exited with code \(result.exitCode)"
    case .uncaughtSignal: "was terminated by signal \(result.exitCode)"
    }
  }

  private func repositoryFailure(
    from error: RepositoryPreparationError
  ) -> (outcome: ExecutionOutcome, exitCode: Int32?, terminationReason: CommandTerminationReason?) {
    switch error {
    case .deadlineExceeded:
      (.timedOut, nil, nil)
    case let .commandFailed(_, result):
      (executionOutcome(for: result.outcome), result.exitCode, result.terminationReason)
    }
  }
}

/// The outcome of orchestration before workspace cleanup runs.
private struct Execution {
  let outcome: ExecutionOutcome
  let stepResults: [StepResult]
  let failureReason: String?
}

private actor JobLogSequencer {
  private var nextSequence: UInt64 = 0
  private let handler: LogHandler

  init(handler: @escaping LogHandler) {
    self.handler = handler
  }

  func forward(_ event: LogEvent) async {
    let resequenced = LogEvent(
      sequence: nextSequence,
      stepID: event.stepID,
      stream: event.stream,
      timestamp: event.timestamp,
      text: event.text
    )
    nextSequence += 1
    await handler(resequenced)
  }
}
