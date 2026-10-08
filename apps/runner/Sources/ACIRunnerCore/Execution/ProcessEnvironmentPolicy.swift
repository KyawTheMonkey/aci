import Foundation

/// Selects which runner environment variables job processes may inherit.
///
/// Repository code must not receive the runner's complete environment. A
/// future service process will hold runner credentials, lease tokens, and
/// proxy settings there, and none of them belong in a build. Steps receive a
/// small allowlist of host variables plus the ACI job variables described by
/// ``JobEnvironment``.
public struct ProcessEnvironmentPolicy: Sendable, Equatable {
  /// Host variables that Xcode, Git, and shells need to behave normally.
  ///
  /// `TMPDIR` is inherited only as a fallback; ``JobExecutor`` replaces it with
  /// a directory inside the job workspace so temporary files are removed with
  /// the job. Locale variables with the `LC_` prefix are always inherited.
  public static let defaultInheritedVariables: Set<String> = [
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "TERM",
    "TMPDIR",
    "LANG",
    "COMMAND_MODE",
    "DEVELOPER_DIR",
    "__CF_USER_TEXT_ENCODING",
    "XPC_FLAGS",
    "XPC_SERVICE_NAME",
  ]

  /// Variable names copied from the runner environment when present.
  public let inheritedVariables: Set<String>

  /// Creates an environment policy.
  /// - Parameter inheritedVariables: Exact names that may be inherited.
  public init(inheritedVariables: Set<String> = Self.defaultInheritedVariables) {
    self.inheritedVariables = inheritedVariables
  }

  /// Returns the permitted subset of `source`.
  /// - Parameter source: The runner environment; defaults to the current process.
  public func environment(
    inheriting source: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    source.filter { key, _ in
      inheritedVariables.contains(key) || key.hasPrefix("LC_")
    }
  }
}

/// Environment variables the runner provides to every job step.
public enum JobEnvironment {
  /// Set to `true` so tools detect a continuous-integration environment.
  public static let ci = "CI"
  /// Set to `true` to identify the ACI runner specifically.
  public static let aci = "ACI"
  /// The lowercase job identifier.
  public static let jobID = "ACI_JOB_ID"
  /// The absolute workspace root for the job attempt.
  public static let workspace = "ACI_WORKSPACE"
  /// The checked-out commit SHA when the job prepared a repository.
  public static let commitSHA = "ACI_COMMIT_SHA"
  /// The job-scoped temporary directory, also exported as `TMPDIR`.
  public static let temporaryDirectory = "ACI_TMPDIR"
}
