import Foundation

/// The normalized, versioned description of work accepted by an ACI runner.
///
/// This is an execution contract rather than the user-facing workflow format.
/// The control plane will eventually compile `.aci.yml` into this type. A
/// runner must still validate every received specification before performing
/// filesystem or process side effects.
public struct JobSpecification: Codable, Sendable, Equatable {
  /// The schema version used to encode this specification.
  public let version: Int

  /// The stable control-plane identifier for this job.
  public let jobID: UUID

  /// The maximum wall-clock duration for the complete job.
  public let timeoutSeconds: Int

  /// Workspace creation and cleanup behavior.
  public let workspace: WorkspaceSpecification

  /// Commands to execute sequentially.
  public let steps: [StepSpecification]

  /// Outputs to collect after execution.
  public let artifacts: [ArtifactSpecification]

  /// Creates a normalized job specification.
  public init(
    version: Int,
    jobID: UUID,
    timeoutSeconds: Int,
    workspace: WorkspaceSpecification,
    steps: [StepSpecification],
    artifacts: [ArtifactSpecification]
  ) {
    self.version = version
    self.jobID = jobID
    self.timeoutSeconds = timeoutSeconds
    self.workspace = workspace
    self.steps = steps
    self.artifacts = artifacts
  }
}
