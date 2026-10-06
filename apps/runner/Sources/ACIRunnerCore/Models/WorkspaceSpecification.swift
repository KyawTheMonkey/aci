import Foundation

/// Controls the lifecycle of the isolated directory assigned to a job.
public struct WorkspaceSpecification: Codable, Sendable, Equatable {
  /// Whether the runner removes the workspace after any terminal outcome.
  public let cleanAfterExecution: Bool

  /// Creates workspace lifecycle settings.
  public init(cleanAfterExecution: Bool) {
    self.cleanAfterExecution = cleanAfterExecution
  }
}
