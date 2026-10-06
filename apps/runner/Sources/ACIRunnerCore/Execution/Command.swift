import Foundation

/// A validated operating-system process invocation.
///
/// Unlike ``StepSpecification``, this type contains resolved runtime values:
/// the executable and working directory are file URLs, and the environment is
/// ready to pass directly to the process-execution backend.
public struct Command: Sendable, Equatable {
  /// The absolute location of the executable to launch.
  public let executableURL: URL
  /// Arguments passed without shell interpretation.
  public let arguments: [String]
  /// The complete environment inherited by the subprocess.
  public let environment: [String: String]
  /// The resolved directory in which the process starts.
  public let workingDirectoryURL: URL

  /// Creates a runtime command.
  public init(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectoryURL: URL
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.workingDirectoryURL = workingDirectoryURL
  }
}
