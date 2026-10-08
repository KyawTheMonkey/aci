import Foundation

/// Hard safety bounds enforced by a runner when it accepts a job.
///
/// The control plane may enforce stricter product policies. These limits are
/// runner-owned guardrails and must not be relaxed merely because a remote
/// caller claims that a job was previously validated.
public struct JobSpecificationValidationLimits: Sendable, Equatable {
  /// The only job schema version this runner understands.
  public let supportedVersion: Int
  /// The longest permitted overall job duration.
  public let maximumJobTimeoutSeconds: Int
  /// The longest permitted timeout for an individual step.
  public let maximumStepTimeoutSeconds: Int
  /// The largest number of sequential steps in one job.
  public let maximumStepCount: Int
  /// The largest accepted step identifier.
  public let maximumIdentifierLength: Int
  /// The largest accepted executable, working-directory, or artifact path.
  public let maximumPathLength: Int
  /// The largest accepted step display name.
  public let maximumNameLength: Int
  /// The largest combined size of one step's executable, arguments, and
  /// environment. The kernel rejects anything near `ARG_MAX` at spawn time;
  /// rejecting it here reports a malformed job instead of a runner fault.
  public let maximumCommandBytes: Int
  /// Whether local `file://` repositories are accepted for offline testing.
  public let allowsFileRepositoryURLs: Bool

  /// Creates runner-side validation limits.
  public init(
    supportedVersion: Int = 1,
    maximumJobTimeoutSeconds: Int = 86_400,
    maximumStepTimeoutSeconds: Int = 21_600,
    maximumStepCount: Int = 100,
    maximumIdentifierLength: Int = 128,
    maximumPathLength: Int = 4_096,
    maximumNameLength: Int = 256,
    maximumCommandBytes: Int = 262_144,
    allowsFileRepositoryURLs: Bool = false
  ) {
    self.supportedVersion = supportedVersion
    self.maximumJobTimeoutSeconds = maximumJobTimeoutSeconds
    self.maximumStepTimeoutSeconds = maximumStepTimeoutSeconds
    self.maximumStepCount = maximumStepCount
    self.maximumIdentifierLength = maximumIdentifierLength
    self.maximumPathLength = maximumPathLength
    self.maximumNameLength = maximumNameLength
    self.maximumCommandBytes = maximumCommandBytes
    self.allowsFileRepositoryURLs = allowsFileRepositoryURLs
  }
}

/// A semantic violation found in a decoded job specification.
///
/// Associated values retain enough context to produce useful CLI messages now
/// and structured control-plane diagnostics in the future.
public enum JobSpecificationError: LocalizedError, Sendable, Equatable {
  case unsupportedVersion(received: Int, supported: Int)
  case invalidJobTimeout(received: Int, maximum: Int)
  case invalidRepositoryURL
  case repositoryURLContainsCredentials
  case invalidCommitSHA(String)
  case noSteps
  case tooManySteps(received: Int, maximum: Int)
  case emptyStepID(index: Int)
  case invalidStepID(index: Int, id: String)
  case duplicateStepID(String)
  case emptyStepName(stepID: String)
  case stepNameTooLong(stepID: String, received: Int, maximum: Int)
  case invalidArgument(stepID: String, index: Int)
  case invalidEnvironmentValue(stepID: String, name: String)
  case commandTooLarge(stepID: String, received: Int, maximum: Int)
  case invalidStepTimeout(stepID: String, received: Int, maximum: Int)
  case stepTimeoutExceedsJobTimeout(stepID: String)
  case nonAbsoluteExecutable(stepID: String, path: String)
  case ambiguousExecutable(stepID: String, path: String)
  case invalidWorkingDirectory(stepID: String, path: String)
  case reservedStepID(index: Int, id: String)
  case invalidEnvironmentVariable(stepID: String, name: String)
  case invalidArtifactPath(index: Int, path: String)
  case duplicateArtifactPath(String)

  public var errorDescription: String? {
    switch self {
    case let .unsupportedVersion(received, supported):
      "Unsupported job specification version \(received); this runner supports version \(supported)."
    case let .invalidJobTimeout(received, maximum):
      "Job timeout must be between 1 and \(maximum) seconds; received \(received)."
    case .invalidRepositoryURL:
      "Repository clone URL must use an allowed absolute scheme without a query or fragment."
    case .repositoryURLContainsCredentials:
      "Repository clone URL must not contain credentials."
    case let .invalidCommitSHA(commitSHA):
      "Repository commit SHA must contain exactly 40 lowercase hexadecimal characters; received '\(commitSHA)'."
    case .noSteps:
      "A job must contain at least one step."
    case let .tooManySteps(received, maximum):
      "A job may contain at most \(maximum) steps; received \(received)."
    case let .emptyStepID(index):
      "Step at index \(index) has an empty identifier."
    case let .invalidStepID(index, id):
      "Step at index \(index) has an invalid identifier '\(id)'."
    case let .duplicateStepID(id):
      "Step identifier '\(id)' is duplicated."
    case let .emptyStepName(stepID):
      "Step '\(stepID)' has an empty display name."
    case let .stepNameTooLong(stepID, received, maximum):
      "Step '\(stepID)' display name may contain at most \(maximum) characters; received \(received)."
    case let .invalidArgument(stepID, index):
      "Step '\(stepID)' argument at index \(index) contains a null byte."
    case let .invalidEnvironmentValue(stepID, name):
      "Step '\(stepID)' environment variable '\(name)' contains a null byte."
    case let .commandTooLarge(stepID, received, maximum):
      "Step '\(stepID)' command may use at most \(maximum) bytes of arguments and environment; received \(received)."
    case let .invalidStepTimeout(stepID, received, maximum):
      "Step '\(stepID)' timeout must be between 1 and \(maximum) seconds; received \(received)."
    case let .stepTimeoutExceedsJobTimeout(stepID):
      "Step '\(stepID)' timeout exceeds the job timeout."
    case let .nonAbsoluteExecutable(stepID, path):
      "Step '\(stepID)' executable must be an absolute path; received '\(path)'."
    case let .ambiguousExecutable(stepID, path):
      "Step '\(stepID)' executable contains ambiguous path components: '\(path)'."
    case let .invalidWorkingDirectory(stepID, path):
      "Step '\(stepID)' working directory must be a safe workspace-relative path; received '\(path)'."
    case let .reservedStepID(index, id):
      "Step at index \(index) uses the reserved identifier '\(id)'."
    case let .invalidEnvironmentVariable(stepID, name):
      "Step '\(stepID)' contains an invalid environment variable name '\(name)'."
    case let .invalidArtifactPath(index, path):
      "Artifact at index \(index) must be a safe workspace-relative path; received '\(path)'."
    case let .duplicateArtifactPath(path):
      "Artifact path '\(path)' is duplicated."
    }
  }
}

/// Performs deterministic validation before a runner creates a workspace or
/// launches a process.
///
/// The validator deliberately performs no filesystem lookups. For example, an
/// absolute executable may pass validation and later fail to launch; that is a
/// runtime infrastructure failure rather than a malformed specification.
public struct JobSpecificationValidator: Sendable {
  /// Safety limits applied to every specification.
  public let limits: JobSpecificationValidationLimits

  /// Creates a validator with the supplied runner-side limits.
  public init(limits: JobSpecificationValidationLimits = .init()) {
    self.limits = limits
  }

  /// Validates all top-level, step, environment, and artifact constraints.
  /// - Parameter specification: The decoded job to inspect.
  /// - Throws: ``JobSpecificationError`` for the first deterministic violation.
  public func validate(_ specification: JobSpecification) throws {
    try validateVersion(specification.version)
    try validateJobTimeout(specification.timeoutSeconds)
    try validateRepository(specification.repository)
    try validateSteps(
      specification.steps,
      jobTimeoutSeconds: specification.timeoutSeconds,
      reservesCheckoutStep: specification.repository != nil
    )
    try validateArtifacts(specification.artifacts)
  }

  private func validateVersion(_ version: Int) throws {
    guard version == limits.supportedVersion else {
      throw JobSpecificationError.unsupportedVersion(
        received: version,
        supported: limits.supportedVersion
      )
    }
  }

  private func validateJobTimeout(_ timeout: Int) throws {
    guard (1...limits.maximumJobTimeoutSeconds).contains(timeout) else {
      throw JobSpecificationError.invalidJobTimeout(
        received: timeout,
        maximum: limits.maximumJobTimeoutSeconds
      )
    }
  }

  private func validateRepository(_ repository: RepositorySpecification?) throws {
    guard let repository else { return }

    let cloneURL = repository.cloneURL
    let renderedURL = cloneURL.absoluteString
    guard renderedURL.count <= limits.maximumPathLength,
          let components = URLComponents(url: cloneURL, resolvingAgainstBaseURL: false)
    else {
      throw JobSpecificationError.invalidRepositoryURL
    }

    guard components.user == nil, components.password == nil else {
      throw JobSpecificationError.repositoryURLContainsCredentials
    }

    let isHTTPS = components.scheme?.lowercased() == "https"
      && !(components.host?.isEmpty ?? true)
    let isAllowedFileURL = limits.allowsFileRepositoryURLs
      && cloneURL.isFileURL
      && (components.host?.isEmpty ?? true)
      && NSString(string: components.path).isAbsolutePath

    guard isHTTPS || isAllowedFileURL,
          !components.path.isEmpty,
          components.path != "/",
          components.query == nil,
          components.fragment == nil
    else {
      throw JobSpecificationError.invalidRepositoryURL
    }

    let commitSHA = repository.commitSHA
    guard commitSHA.count == 40,
          commitSHA.unicodeScalars.allSatisfy({ scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
          })
    else {
      throw JobSpecificationError.invalidCommitSHA(commitSHA)
    }
  }

  private func validateSteps(
    _ steps: [StepSpecification],
    jobTimeoutSeconds: Int,
    reservesCheckoutStep: Bool
  ) throws {
    guard !steps.isEmpty else {
      throw JobSpecificationError.noSteps
    }

    guard steps.count <= limits.maximumStepCount else {
      throw JobSpecificationError.tooManySteps(
        received: steps.count,
        maximum: limits.maximumStepCount
      )
    }

    var identifiers = Set<String>()

    for (index, step) in steps.enumerated() {
      let trimmedID = step.id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedID.isEmpty else {
        throw JobSpecificationError.emptyStepID(index: index)
      }

      if reservesCheckoutStep,
         step.id == RepositorySpecification.checkoutStepID {
        throw JobSpecificationError.reservedStepID(index: index, id: step.id)
      }

      guard trimmedID == step.id,
            step.id.count <= limits.maximumIdentifierLength,
            step.id.unicodeScalars.allSatisfy(isValidIdentifierScalar)
      else {
        throw JobSpecificationError.invalidStepID(index: index, id: step.id)
      }

      guard identifiers.insert(step.id).inserted else {
        throw JobSpecificationError.duplicateStepID(step.id)
      }

      guard !step.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw JobSpecificationError.emptyStepName(stepID: step.id)
      }

      guard step.name.count <= limits.maximumNameLength else {
        throw JobSpecificationError.stepNameTooLong(
          stepID: step.id,
          received: step.name.count,
          maximum: limits.maximumNameLength
        )
      }

      if let timeout = step.timeoutSeconds {
        guard (1...limits.maximumStepTimeoutSeconds).contains(timeout) else {
          throw JobSpecificationError.invalidStepTimeout(
            stepID: step.id,
            received: timeout,
            maximum: limits.maximumStepTimeoutSeconds
          )
        }

        guard timeout <= jobTimeoutSeconds else {
          throw JobSpecificationError.stepTimeoutExceedsJobTimeout(stepID: step.id)
        }
      }

      try validateExecutable(step.executable, stepID: step.id)

      if let workingDirectory = step.workingDirectory,
         !isSafeRelativePath(workingDirectory, allowCurrentDirectory: true)
      {
        throw JobSpecificationError.invalidWorkingDirectory(
          stepID: step.id,
          path: workingDirectory
        )
      }

      for (index, argument) in step.arguments.enumerated() where argument.containsNullByte {
        throw JobSpecificationError.invalidArgument(stepID: step.id, index: index)
      }

      for (name, value) in step.environment {
        guard isValidEnvironmentVariableName(name) else {
          throw JobSpecificationError.invalidEnvironmentVariable(stepID: step.id, name: name)
        }
        guard !value.containsNullByte else {
          throw JobSpecificationError.invalidEnvironmentValue(stepID: step.id, name: name)
        }
      }

      try validateCommandSize(of: step)
    }
  }

  private func validateExecutable(_ path: String, stepID: String) throws {
    // `NSString.isAbsolutePath` also accepts `~` and `~user` prefixes, which
    // would resolve relative to the runner account or its working directory.
    guard path.count <= limits.maximumPathLength,
          path.hasPrefix("/")
    else {
      throw JobSpecificationError.nonAbsoluteExecutable(stepID: stepID, path: path)
    }

    let components = NSString(string: path).pathComponents
    guard !components.contains(".."), !path.containsNullByte else {
      throw JobSpecificationError.ambiguousExecutable(stepID: stepID, path: path)
    }
  }

  /// Counts the bytes `posix_spawn` must copy for the argument and environment
  /// vectors, including each entry's terminating null byte and the `=` that
  /// joins environment names to values.
  private func validateCommandSize(of step: StepSpecification) throws {
    var bytes = step.executable.utf8.count + 1
    for argument in step.arguments {
      bytes += argument.utf8.count + 1
    }
    for (name, value) in step.environment {
      bytes += name.utf8.count + value.utf8.count + 2
    }

    guard bytes <= limits.maximumCommandBytes else {
      throw JobSpecificationError.commandTooLarge(
        stepID: step.id,
        received: bytes,
        maximum: limits.maximumCommandBytes
      )
    }
  }

  private func validateArtifacts(_ artifacts: [ArtifactSpecification]) throws {
    var paths = Set<String>()

    for (index, artifact) in artifacts.enumerated() {
      guard isSafeRelativePath(artifact.path, allowCurrentDirectory: false) else {
        throw JobSpecificationError.invalidArtifactPath(index: index, path: artifact.path)
      }

      guard paths.insert(artifact.path).inserted else {
        throw JobSpecificationError.duplicateArtifactPath(artifact.path)
      }
    }
  }

  private func isSafeRelativePath(_ path: String, allowCurrentDirectory: Bool) -> Bool {
    guard !path.isEmpty,
          path.count <= limits.maximumPathLength,
          !NSString(string: path).isAbsolutePath,
          !path.containsNullByte,
          path != "~",
          !path.hasPrefix("~/")
    else {
      return false
    }

    let components = NSString(string: path).pathComponents
    guard !components.contains("..") else {
      return false
    }

    return allowCurrentDirectory || path != "."
  }

  private func isValidIdentifierScalar(_ scalar: UnicodeScalar) -> Bool {
    CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
  }

  private func isValidEnvironmentVariableName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first,
          first == "_" || CharacterSet.letters.contains(first)
    else {
      return false
    }

    return name.unicodeScalars.dropFirst().allSatisfy { scalar in
      scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }
  }
}

private extension String {
  var containsNullByte: Bool {
    unicodeScalars.contains { $0.value == 0 }
  }
}
