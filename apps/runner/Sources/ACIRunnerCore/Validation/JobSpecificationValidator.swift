import Foundation

public enum JobSpecificationError: LocalizedError {
  case unsupportedVersion
  case invalidJobTimeout
  case noSteps
  case duplicateStepID
  case emptyStepID
  case invalidStepTimeout
  case nonAbsoluteExecutable
  case absoluteWorkingDirectory
  case invalidArtifactPath
}
