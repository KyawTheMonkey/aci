import ACIRunnerCore
import Testing

@Suite("Job specification validator")
struct JobSpecificationValidatorTests {
  private let validator = JobSpecificationValidator()

  @Test("A valid specification passes")
  func validSpecification() throws {
    try validator.validate(makeJob())
  }

  @Test("Unsupported versions are rejected")
  func unsupportedVersion() {
    expectValidationError(
      .unsupportedVersion(received: 2, supported: 1),
      for: makeJob(version: 2)
    )
  }

  @Test("Job timeout must be positive")
  func invalidJobTimeout() {
    expectValidationError(
      .invalidJobTimeout(received: 0, maximum: 86_400),
      for: makeJob(timeoutSeconds: 0)
    )
  }

  @Test("A job requires at least one step")
  func noSteps() {
    expectValidationError(.noSteps, for: makeJob(steps: []))
  }

  @Test("Step identifiers must be unique")
  func duplicateStepID() {
    expectValidationError(
      .duplicateStepID("test"),
      for: makeJob(steps: [makeStep(), makeStep()])
    )
  }

  @Test("Whitespace-only step identifiers are rejected")
  func emptyStepID() {
    expectValidationError(
      .emptyStepID(index: 0),
      for: makeJob(steps: [makeStep(id: "   ")])
    )
  }

  @Test("Executables must be absolute paths")
  func relativeExecutable() {
    expectValidationError(
      .nonAbsoluteExecutable(stepID: "test", path: "swift"),
      for: makeJob(steps: [makeStep(executable: "swift")])
    )
  }

  @Test("Working directories cannot escape the workspace")
  func unsafeWorkingDirectory() {
    expectValidationError(
      .invalidWorkingDirectory(stepID: "test", path: "../outside"),
      for: makeJob(steps: [makeStep(workingDirectory: "../outside")])
    )
  }

  @Test("Environment variable names use portable identifier syntax")
  func invalidEnvironmentVariable() {
    expectValidationError(
      .invalidEnvironmentVariable(stepID: "test", name: "NOT-VALID"),
      for: makeJob(steps: [makeStep(environment: ["NOT-VALID": "value"])])
    )
  }

  @Test("Artifact paths cannot escape the workspace")
  func unsafeArtifactPath() {
    expectValidationError(
      .invalidArtifactPath(index: 0, path: "../../private-key"),
      for: makeJob(
        artifacts: [ArtifactSpecification(path: "../../private-key", required: true)]
      )
    )
  }

  private func expectValidationError(
    _ expected: JobSpecificationError,
    for specification: JobSpecification,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    do {
      try validator.validate(specification)
      Issue.record("Expected validation to fail.", sourceLocation: sourceLocation)
    } catch let error as JobSpecificationError {
      #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
      Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
    }
  }
}
