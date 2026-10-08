import Foundation

/// A terminal outcome shared by jobs and steps.
public enum ExecutionOutcome: String, Codable, Sendable, Equatable {
  case succeeded
  case failed
  case cancelled
  case timedOut
  case infrastructureFailed
}

/// The durable result of one normalized job step.
public struct StepResult: Codable, Sendable, Equatable {
  /// The identifier from the originating step specification.
  public let stepID: String
  /// The runner's classification of the step outcome.
  public let outcome: ExecutionOutcome
  /// The process exit status, or the terminating signal number, when a
  /// process launched; otherwise `nil`.
  public let exitCode: Int32?
  /// Whether ``exitCode`` is an exit status or a signal number.
  ///
  /// Without this, a step that exited with status 9 would be indistinguishable
  /// from one the runner force-killed with `SIGKILL`.
  public let terminationReason: CommandTerminationReason?
  /// When execution of this step began.
  public let startedAt: Date
  /// When execution and output draining finished.
  public let finishedAt: Date
  /// A human-readable diagnostic for unsuccessful outcomes.
  public let failureReason: String?

  /// Creates a step result.
  public init(
    stepID: String,
    outcome: ExecutionOutcome,
    exitCode: Int32?,
    terminationReason: CommandTerminationReason? = nil,
    startedAt: Date,
    finishedAt: Date,
    failureReason: String?
  ) {
    self.stepID = stepID
    self.outcome = outcome
    self.exitCode = exitCode
    self.terminationReason = terminationReason
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.failureReason = failureReason
  }
}

/// The terminal result of executing a complete normalized job.
public struct JobResult: Codable, Sendable, Equatable {
  /// The identifier of the executed job.
  public let jobID: UUID
  /// The final job-level outcome.
  public let outcome: ExecutionOutcome
  /// Results for steps that started, in execution order.
  public let stepResults: [StepResult]
  /// When job orchestration began.
  public let startedAt: Date
  /// When the job reached its terminal state.
  public let finishedAt: Date
  /// A human-readable job-level diagnostic.
  public let failureReason: String?
  /// Runner-side problems that did not change the outcome, such as a
  /// workspace that could not be removed. Operators must see these: a silent
  /// cleanup failure eventually fills the disk.
  public let warnings: [String]

  /// Creates a complete job result.
  public init(
    jobID: UUID,
    outcome: ExecutionOutcome,
    stepResults: [StepResult],
    startedAt: Date,
    finishedAt: Date,
    failureReason: String?,
    warnings: [String] = []
  ) {
    self.jobID = jobID
    self.outcome = outcome
    self.stepResults = stepResults
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.failureReason = failureReason
    self.warnings = warnings
  }
}
