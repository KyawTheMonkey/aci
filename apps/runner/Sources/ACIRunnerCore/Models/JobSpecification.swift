import Foundation

public struct JobSpecification: Codable, Sendable {
  public let version: Int
  public let jobID: UUID
  public let timeoutSeconds: Int
  public let workspace: WorkspaceSpecification
  public let steps: [StepSpecification]
  public let artifacts: [ArtifactSpecification]

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
