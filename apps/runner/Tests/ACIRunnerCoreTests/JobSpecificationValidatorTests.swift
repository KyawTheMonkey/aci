import ACIRunnerCore
import Foundation
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

  @Test("A repository uses a credential-free HTTPS URL")
  func invalidRepositoryURL() {
    expectValidationError(
      .invalidRepositoryURL,
      for: makeJob(
        repository: makeRepository(
          cloneURL: URL(string: "http://github.com/example/ios-app.git")!
        )
      )
    )
  }

  @Test("Local repository URLs are rejected by default")
  func localRepositoryRejectedByDefault() {
    expectValidationError(
      .invalidRepositoryURL,
      for: makeJob(
        repository: makeRepository(
          cloneURL: URL(fileURLWithPath: "/private/tmp/aci-source")
        )
      )
    )
  }

  @Test("Local repository URLs require an explicit validation policy")
  func localRepositoryAllowedForAcceptanceTesting() throws {
    let localValidator = JobSpecificationValidator(
      limits: JobSpecificationValidationLimits(allowsFileRepositoryURLs: true)
    )
    let specification = makeJob(
      repository: makeRepository(
        cloneURL: URL(fileURLWithPath: "/private/tmp/aci-source")
      )
    )

    try localValidator.validate(specification)
  }

  @Test("Repository credentials cannot be embedded in the clone URL")
  func repositoryCredentials() {
    expectValidationError(
      .repositoryURLContainsCredentials,
      for: makeJob(
        repository: makeRepository(
          cloneURL: URL(string: "https://token@github.com/example/ios-app.git")!
        )
      )
    )
  }

  @Test("Repository URLs cannot carry query credentials")
  func repositoryQuery() {
    let cloneURL = URL(string: "https://github.com/example/ios-app.git?token=secret")!
    expectValidationError(
      .invalidRepositoryURL,
      for: makeJob(repository: makeRepository(cloneURL: cloneURL))
    )
  }

  @Test("A commit SHA must be complete lowercase hexadecimal")
  func invalidCommitSHA() {
    expectValidationError(
      .invalidCommitSHA("ABC123"),
      for: makeJob(repository: makeRepository(commitSHA: "ABC123"))
    )
  }

  @Test("Checkout is reserved when repository preparation is enabled")
  func reservedCheckoutStep() {
    expectValidationError(
      .reservedStepID(index: 0, id: "checkout"),
      for: makeJob(
        repository: makeRepository(),
        steps: [makeStep(id: "checkout")]
      )
    )
  }

  @Test("Tilde-prefixed executables are not absolute", arguments: ["~/bin/tool", "~runner/bin/tool"])
  func tildeExecutables(path: String) {
    expectValidationError(
      .nonAbsoluteExecutable(stepID: "test", path: path),
      for: makeJob(steps: [makeStep(executable: path)])
    )
  }

  @Test("Step names are bounded")
  func stepNameLength() {
    let name = String(repeating: "n", count: 257)
    expectValidationError(
      .stepNameTooLong(stepID: "test", received: 257, maximum: 256),
      for: makeJob(steps: [makeStep(name: name)])
    )
  }

  @Test("Arguments and environment values cannot contain null bytes")
  func nullBytes() {
    expectValidationError(
      .invalidArgument(stepID: "test", index: 1),
      for: makeJob(steps: [makeStep(arguments: ["ok", "bad\u{0}"])])
    )
    expectValidationError(
      .invalidEnvironmentValue(stepID: "test", name: "TOKEN"),
      for: makeJob(steps: [makeStep(environment: ["TOKEN": "bad\u{0}"])])
    )
  }

  @Test("Oversized commands are rejected before spawn")
  func commandSize() {
    let limitedValidator = JobSpecificationValidator(
      limits: JobSpecificationValidationLimits(maximumCommandBytes: 64)
    )
    let step = makeStep(arguments: [String(repeating: "a", count: 64)])

    // "/usr/bin/true" plus its terminator is 14 bytes; the argument adds 65.
    #expect(throws: JobSpecificationError.commandTooLarge(stepID: "test", received: 79, maximum: 64)) {
      try limitedValidator.validate(makeJob(steps: [step]))
    }
    #expect(throws: Never.self) {
      try validator.validate(makeJob(steps: [step]))
    }
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
