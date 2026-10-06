import Foundation

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

  /// Creates a job executor with injectable filesystem and process backends.
  ///
  /// Dependency injection keeps orchestration tests deterministic and avoids
  /// launching real processes for every job-state test.
  public init(
    validator: JobSpecificationValidator = .init(),
    workspaceManager: any WorkspaceManaging,
    commandExecutor: any CommandExecuting = CommandExecutor(),
    repositoryPreparer: (any RepositoryPreparing)? = nil
  ) {
    self.validator = validator
    self.workspaceManager = workspaceManager
    self.commandExecutor = commandExecutor
    self.repositoryPreparer = repositoryPreparer
      ?? GitRepositoryPreparer(commandExecutor: commandExecutor)
  }

  /// Executes a job while discarding its streamed log events.
  public func execute(_ specification: JobSpecification) async throws -> JobResult {
    try await execute(specification, onLog: { _ in })
  }

  /// Executes a job and forwards globally sequenced log events.
  /// - Parameters:
  ///   - specification: The decoded normalized job contract.
  ///   - onLog: An asynchronous consumer for job-wide log events.
  /// - Returns: A terminal result for every normal execution outcome.
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

    defer {
      if specification.workspace.cleanAfterExecution {
        try? workspaceManager.removeWorkspace(workspace)
      }
    }

    var stepResults: [StepResult] = []

    if let repository = specification.repository {
      let checkoutStartedAt = Date()

      do {
        try await repositoryPreparer.prepare(
          repository,
          in: workspace,
          deadline: deadline,
          onLog: { event in
            await jobLogSequencer.forward(event)
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
            startedAt: checkoutStartedAt,
            finishedAt: Date(),
            failureReason: error.localizedDescription
          )
        )

        return makeJobResult(
          specification: specification,
          outcome: failure.outcome,
          stepResults: stepResults,
          startedAt: jobStartedAt,
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

        return makeJobResult(
          specification: specification,
          outcome: .cancelled,
          stepResults: stepResults,
          startedAt: jobStartedAt,
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

        return makeJobResult(
          specification: specification,
          outcome: .infrastructureFailed,
          stepResults: stepResults,
          startedAt: jobStartedAt,
          failureReason: "Runner could not prepare the repository: \(error.localizedDescription)"
        )
      }
    }

    for step in specification.steps {
      if Task.isCancelled {
        return makeJobResult(
          specification: specification,
          outcome: .cancelled,
          stepResults: stepResults,
          startedAt: jobStartedAt,
          failureReason: "Job execution was cancelled."
        )
      }

      let remainingJobSeconds = Int(ceil(deadline.timeIntervalSinceNow))
      guard remainingJobSeconds > 0 else {
        return makeJobResult(
          specification: specification,
          outcome: .timedOut,
          stepResults: stepResults,
          startedAt: jobStartedAt,
          failureReason: "Job timeout was reached before step '\(step.id)' started."
        )
      }

      let workingDirectory: URL
      if let relativeDirectory = step.workingDirectory, relativeDirectory != "." {
        workingDirectory = try workspaceManager.resolve(relativeDirectory, in: workspace)
      } else {
        workingDirectory = workspace.rootURL
      }

      var environment = ProcessInfo.processInfo.environment
      environment.merge(step.environment) { _, jobValue in jobValue }

      let command = Command(
        executableURL: URL(fileURLWithPath: step.executable).standardizedFileURL,
        arguments: step.arguments,
        environment: environment,
        workingDirectoryURL: workingDirectory
      )
      // A step can request a shorter deadline but can never extend the time
      // remaining on the enclosing job.
      let effectiveTimeout = min(step.timeoutSeconds ?? remainingJobSeconds, remainingJobSeconds)
      let stepStartedAt = Date()

      do {
        let commandResult = try await commandExecutor.execute(
          command,
          stepID: step.id,
          timeoutSeconds: effectiveTimeout,
          onLog: { event in
            await jobLogSequencer.forward(event)
          }
        )
        let outcome = executionOutcome(for: commandResult.outcome)
        let failureReason = failureReason(for: commandResult.outcome)
        let stepResult = StepResult(
          stepID: step.id,
          outcome: outcome,
          exitCode: commandResult.exitCode,
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
          return makeJobResult(
            specification: specification,
            outcome: .failed,
            stepResults: stepResults,
            startedAt: jobStartedAt,
            failureReason: "Step '\(step.id)' exited with code \(commandResult.exitCode)."
          )
        case .timedOut:
          return makeJobResult(
            specification: specification,
            outcome: .timedOut,
            stepResults: stepResults,
            startedAt: jobStartedAt,
            failureReason: "Step '\(step.id)' timed out."
          )
        case .cancelled:
          return makeJobResult(
            specification: specification,
            outcome: .cancelled,
            stepResults: stepResults,
            startedAt: jobStartedAt,
            failureReason: "Step '\(step.id)' was cancelled."
          )
        case .infrastructureFailed:
          assertionFailure("Command execution cannot directly return an infrastructure failure.")
        }
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

        return makeJobResult(
          specification: specification,
          outcome: .infrastructureFailed,
          stepResults: stepResults,
          startedAt: jobStartedAt,
          failureReason: "Runner failed to execute step '\(step.id)': \(error.localizedDescription)"
        )
      }
    }

    return makeJobResult(
      specification: specification,
      outcome: .succeeded,
      stepResults: stepResults,
      startedAt: jobStartedAt,
      failureReason: nil
    )
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

  private func repositoryFailure(
    from error: RepositoryPreparationError
  ) -> (outcome: ExecutionOutcome, exitCode: Int32?) {
    switch error {
    case .deadlineExceeded:
      (.timedOut, nil)
    case let .commandFailed(_, result):
      (executionOutcome(for: result.outcome), result.exitCode)
    }
  }

  private func makeJobResult(
    specification: JobSpecification,
    outcome: ExecutionOutcome,
    stepResults: [StepResult],
    startedAt: Date,
    failureReason: String?
  ) -> JobResult {
    JobResult(
      jobID: specification.jobID,
      outcome: outcome,
      stepResults: stepResults,
      startedAt: startedAt,
      finishedAt: Date(),
      failureReason: failureReason
    )
  }
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
