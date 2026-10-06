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

  /// Creates runner-side validation limits.
  public init(
    supportedVersion: Int = 1,
    maximumJobTimeoutSeconds: Int = 86_400,
    maximumStepTimeoutSeconds: Int = 21_600,
    maximumStepCount: Int = 100,
    maximumIdentifierLength: Int = 128,
    maximumPathLength: Int = 4_096
  ) {
    self.supportedVersion = supportedVersion
    self.maximumJobTimeoutSeconds = maximumJobTimeoutSeconds
    self.maximumStepTimeoutSeconds = maximumStepTimeoutSeconds
    self.maximumStepCount = maximumStepCount
    self.maximumIdentifierLength = maximumIdentifierLength
    self.maximumPathLength = maximumPathLength
  }
}

/// A semantic violation found in a decoded job specification.
///
/// Associated values retain enough context to produce useful CLI messages now
/// and structured control-plane diagnostics in the future.
public enum JobSpecificationError: LocalizedError, Sendable, Equatable {
  case unsupportedVersion(received: Int, supported: Int)
  case invalidJobTimeout(received: Int, maximum: Int)
  case noSteps
  case tooManySteps(received: Int, maximum: Int)
  case emptyStepID(index: Int)
  case invalidStepID(index: Int, id: String)
  case duplicateStepID(String)
  case emptyStepName(stepID: String)
  case invalidStepTimeout(stepID: String, received: Int, maximum: Int)
  case stepTimeoutExceedsJobTimeout(stepID: String)
  case nonAbsoluteExecutable(stepID: String, path: String)
  case ambiguousExecutable(stepID: String, path: String)
  case invalidWorkingDirectory(stepID: String, path: String)
  case invalidEnvironmentVariable(stepID: String, name: String)
  case invalidArtifactPath(index: Int, path: String)
  case duplicateArtifactPath(String)

  public var errorDescription: String? {
    switch self {
    case let .unsupportedVersion(received, supported):
      "Unsupported job specification version \(received); this runner supports version \(supported)."
    case let .invalidJobTimeout(received, maximum):
      "Job timeout must be between 1 and \(maximum) seconds; received \(received)."
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
    try validateSteps(specification.steps, jobTimeoutSeconds: specification.timeoutSeconds)
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

  private func validateSteps(
    _ steps: [StepSpecification],
    jobTimeoutSeconds: Int
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

      for name in step.environment.keys where !isValidEnvironmentVariableName(name) {
        throw JobSpecificationError.invalidEnvironmentVariable(stepID: step.id, name: name)
      }
    }
  }

  private func validateExecutable(_ path: String, stepID: String) throws {
    guard path.count <= limits.maximumPathLength,
          NSString(string: path).isAbsolutePath
    else {
      throw JobSpecificationError.nonAbsoluteExecutable(stepID: stepID, path: path)
    }

    let components = NSString(string: path).pathComponents
    guard !components.contains(".."), !path.containsNullByte else {
      throw JobSpecificationError.ambiguousExecutable(stepID: stepID, path: path)
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
