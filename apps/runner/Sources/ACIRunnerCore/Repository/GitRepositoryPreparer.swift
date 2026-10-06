import Foundation

/// The Git operation that was active when repository preparation stopped.
public enum RepositoryPreparationStage: String, Sendable, Equatable {
  case initialize
  case fetch
  case checkout
}

/// A user-visible Git failure while preparing an otherwise valid repository.
public enum RepositoryPreparationError: LocalizedError, Sendable, Equatable {
  /// The overall job deadline was reached before this operation could start.
  case deadlineExceeded(stage: RepositoryPreparationStage)
  /// Git launched but did not complete successfully.
  case commandFailed(
    stage: RepositoryPreparationStage,
    result: CommandExecutionResult
  )

  public var errorDescription: String? {
    switch self {
    case let .deadlineExceeded(stage):
      "The job deadline was reached before Git could \(stage.description)."
    case let .commandFailed(stage, result):
      switch result.outcome {
      case .failed:
        "Git could not \(stage.description); it exited with code \(result.exitCode)."
      case .timedOut:
        "Git timed out while attempting to \(stage.description)."
      case .cancelled:
        "Git was cancelled while attempting to \(stage.description)."
      case .succeeded:
        "Git reported an unexpected repository-preparation state."
      }
    }
  }
}

/// Prepares source code in a newly created job workspace.
public protocol RepositoryPreparing: Sendable {
  /// Fetches and checks out the requested immutable revision.
  ///
  /// - Parameters:
  ///   - repository: The validated, credential-free source request.
  ///   - workspace: The isolated workspace that will contain the checkout.
  ///   - deadline: The absolute job deadline shared with later command steps.
  ///   - onLog: A consumer for Git stdout and stderr.
  func prepare(
    _ repository: RepositorySpecification,
    in workspace: Workspace,
    deadline: Date,
    onLog: @escaping LogHandler
  ) async throws
}

/// Prepares a repository using the system Git executable.
///
/// Git receives a complete commit SHA rather than a branch or tag. Global and
/// system configuration are disabled so host aliases, hooks, and credential
/// helpers cannot silently change checkout behavior.
public struct GitRepositoryPreparer: RepositoryPreparing, Sendable {
  /// The synthetic step identifier used for checkout logs and results.
  public static let stepID = RepositorySpecification.checkoutStepID

  private let commandExecutor: any CommandExecuting
  private let gitExecutableURL: URL

  /// Creates a Git-backed repository preparer.
  public init(
    commandExecutor: any CommandExecuting = CommandExecutor(),
    gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git")
  ) {
    self.commandExecutor = commandExecutor
    self.gitExecutableURL = gitExecutableURL
  }

  public func prepare(
    _ repository: RepositorySpecification,
    in workspace: Workspace,
    deadline: Date,
    onLog: @escaping LogHandler
  ) async throws {
    let invocations = [
      GitInvocation(
        stage: .initialize,
        arguments: ["init", "--quiet", "."]
      ),
      GitInvocation(
        stage: .fetch,
        arguments: [
          "fetch",
          "--force",
          "--no-tags",
          "--depth",
          "1",
          repository.cloneURL.absoluteString,
          repository.commitSHA,
        ]
      ),
      GitInvocation(
        stage: .checkout,
        arguments: [
          "checkout",
          "--quiet",
          "--force",
          "--detach",
          repository.commitSHA,
        ]
      ),
    ]

    for invocation in invocations {
      try Task.checkCancellation()

      let remainingSeconds = Int(ceil(deadline.timeIntervalSinceNow))
      guard remainingSeconds > 0 else {
        throw RepositoryPreparationError.deadlineExceeded(stage: invocation.stage)
      }

      let result = try await commandExecutor.execute(
        makeCommand(arguments: invocation.arguments, workspace: workspace),
        stepID: Self.stepID,
        timeoutSeconds: remainingSeconds,
        onLog: onLog
      )

      guard result.outcome == .succeeded else {
        throw RepositoryPreparationError.commandFailed(
          stage: invocation.stage,
          result: result
        )
      }
    }
  }

  private func makeCommand(arguments: [String], workspace: Workspace) -> Command {
    var environment = ProcessInfo.processInfo.environment
    for key in Array(environment.keys) where key.hasPrefix("GIT_") {
      environment.removeValue(forKey: key)
    }
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_COUNT"] = "0"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["LC_ALL"] = "C"

    return Command(
      executableURL: gitExecutableURL,
      arguments: arguments,
      environment: environment,
      workingDirectoryURL: workspace.rootURL
    )
  }
}

private struct GitInvocation {
  let stage: RepositoryPreparationStage
  let arguments: [String]
}

private extension RepositoryPreparationStage {
  var description: String {
    switch self {
    case .initialize: "initialize the workspace"
    case .fetch: "fetch the requested commit"
    case .checkout: "check out the requested commit"
    }
  }
}
