import Foundation

/// The terminal outcome of a process that launched successfully.
public enum CommandOutcome: String, Codable, Sendable, Equatable {
  /// The process exited with status zero.
  case succeeded
  /// The process exited with a nonzero status or an unexpected signal.
  case failed
  /// The runner terminated the process after its deadline.
  case timedOut
  /// The runner terminated the process because its parent task was cancelled.
  case cancelled
}

/// A transport-safe representation of `Foundation.Process.TerminationReason`.
public enum CommandTerminationReason: String, Codable, Sendable, Equatable {
  case exit
  case uncaughtSignal
}

/// The measured result of one process invocation.
public struct CommandExecutionResult: Codable, Sendable, Equatable {
  /// The runner-level interpretation of the process result.
  public let outcome: CommandOutcome
  /// The process exit status or terminating signal value reported by Foundation.
  public let exitCode: Int32
  /// Whether the process exited normally or because of an uncaught signal.
  public let terminationReason: CommandTerminationReason
  /// The time at which the runner began preparing the process launch.
  public let startedAt: Date
  /// The time at which process termination and output draining completed.
  public let finishedAt: Date

  /// Creates a measured command result.
  public init(
    outcome: CommandOutcome,
    exitCode: Int32,
    terminationReason: CommandTerminationReason,
    startedAt: Date,
    finishedAt: Date
  ) {
    self.outcome = outcome
    self.exitCode = exitCode
    self.terminationReason = terminationReason
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }
}
