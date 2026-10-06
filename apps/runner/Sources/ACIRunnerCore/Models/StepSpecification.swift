import Foundation

/// The execution behavior requested by a normalized job step.
public enum StepKind: String, Codable, Sendable {
  /// Launch an executable with an explicit argument vector.
  case command
}

/// Describes one sequential unit of work in a job.
///
/// Executables and arguments are modeled separately so the runner does not
/// implicitly invoke a shell. A workflow that needs shell syntax must request
/// a shell explicitly, for example `/bin/zsh` with `-lc` arguments.
public struct StepSpecification: Codable, Sendable, Equatable {
  /// A job-unique identifier used in logs and results.
  public let id: String

  /// A user-facing label for the step.
  public let name: String

  /// The execution behavior for the step.
  public let kind: StepKind

  /// An absolute path to the executable.
  public let executable: String

  /// Arguments passed directly to the executable.
  public let arguments: [String]

  /// Environment values that override the runner's inherited environment.
  public let environment: [String: String]

  /// An optional working directory relative to the job workspace.
  public let workingDirectory: String?

  /// An optional step deadline that is additionally capped by the job deadline.
  public let timeoutSeconds: Int?

  /// Whether a nonzero exit code permits later steps to execute.
  public let continueOnError: Bool

  /// Creates a normalized command step.
  public init(
    id: String,
    name: String,
    kind: StepKind,
    executable: String,
    arguments: [String],
    environment: [String: String],
    workingDirectory: String?,
    timeoutSeconds: Int?,
    continueOnError: Bool
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.timeoutSeconds = timeoutSeconds
    self.continueOnError = continueOnError
  }
}
