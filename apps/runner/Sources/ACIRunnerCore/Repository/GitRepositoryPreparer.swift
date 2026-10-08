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
///
/// Fetching is the only network operation, so it is the only stage that is
/// retried. Transient transport failures are retried with a short backoff;
/// failures that cannot succeed on retry, such as an unknown commit or a
/// rejected credential, fail immediately.
public struct GitRepositoryPreparer: RepositoryPreparing, Sendable {
  /// The synthetic step identifier used for checkout logs and results.
  public static let stepID = RepositorySpecification.checkoutStepID

  /// The pause before each fetch retry; the count bounds the number of retries.
  public static let defaultFetchRetryDelays: [Duration] = [.seconds(2), .seconds(5)]

  private let commandExecutor: any CommandExecuting
  private let gitExecutableURL: URL
  private let environmentPolicy: ProcessEnvironmentPolicy
  private let fetchRetryDelays: [Duration]

  /// Creates a Git-backed repository preparer.
  public init(
    commandExecutor: any CommandExecuting = CommandExecutor(),
    gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
    environmentPolicy: ProcessEnvironmentPolicy = .init(),
    fetchRetryDelays: [Duration] = GitRepositoryPreparer.defaultFetchRetryDelays
  ) {
    self.commandExecutor = commandExecutor
    self.gitExecutableURL = gitExecutableURL
    self.environmentPolicy = environmentPolicy
    self.fetchRetryDelays = fetchRetryDelays
  }

  public func prepare(
    _ repository: RepositorySpecification,
    in workspace: Workspace,
    deadline: Date,
    onLog: @escaping LogHandler
  ) async throws {
    try await runOnce(
      GitInvocation(stage: .initialize, arguments: ["init", "--quiet", "."]),
      in: workspace,
      deadline: deadline,
      onLog: onLog
    )

    try await fetchWithRetries(
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
      in: workspace,
      deadline: deadline,
      onLog: onLog
    )

    try await runOnce(
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
      in: workspace,
      deadline: deadline,
      onLog: onLog
    )
  }

  private func runOnce(
    _ invocation: GitInvocation,
    in workspace: Workspace,
    deadline: Date,
    onLog: @escaping LogHandler
  ) async throws {
    let result = try await run(invocation, in: workspace, deadline: deadline, onLog: onLog)
    guard result.outcome == .succeeded else {
      throw RepositoryPreparationError.commandFailed(stage: invocation.stage, result: result)
    }
  }

  private func fetchWithRetries(
    _ invocation: GitInvocation,
    in workspace: Workspace,
    deadline: Date,
    onLog: @escaping LogHandler
  ) async throws {
    var attempt = 0

    while true {
      let diagnostics = StandardErrorCollector()
      let result = try await run(
        invocation,
        in: workspace,
        deadline: deadline,
        onLog: { event in
          if event.stream == .stderr {
            await diagnostics.append(event.text)
          }
          await onLog(event)
        }
      )

      if result.outcome == .succeeded {
        return
      }

      let failure = RepositoryPreparationError.commandFailed(stage: invocation.stage, result: result)
      guard result.outcome == .failed,
            attempt < fetchRetryDelays.count,
            isRetryable(await diagnostics.text)
      else {
        throw failure
      }

      let delay = fetchRetryDelays[attempt]
      attempt += 1

      // Do not start a wait that would consume the time a retry needs.
      let delaySeconds = TimeInterval(delay.components.seconds)
      guard deadline.timeIntervalSinceNow > delaySeconds + 1 else {
        throw failure
      }

      await onLog(
        LogEvent(
          sequence: 0,
          stepID: Self.stepID,
          stream: .stderr,
          timestamp: Date(),
          text: "aci-runner: fetch failed with a transient error; retrying in \(Int(delaySeconds))s "
            + "(retry \(attempt) of \(fetchRetryDelays.count)).\n"
        )
      )
      try await Task.sleep(for: delay)
    }
  }

  private func run(
    _ invocation: GitInvocation,
    in workspace: Workspace,
    deadline: Date,
    onLog: @escaping LogHandler
  ) async throws -> CommandExecutionResult {
    try Task.checkCancellation()

    let remainingSeconds = Int(ceil(deadline.timeIntervalSinceNow))
    guard remainingSeconds > 0 else {
      throw RepositoryPreparationError.deadlineExceeded(stage: invocation.stage)
    }

    return try await commandExecutor.execute(
      makeCommand(arguments: invocation.arguments, workspace: workspace),
      stepID: Self.stepID,
      timeoutSeconds: remainingSeconds,
      onLog: onLog
    )
  }

  /// Decides whether a failed fetch could succeed if repeated.
  ///
  /// Git reports permanent conditions with recognizable phrases. Anything
  /// else, such as a connection reset, a timeout, or a 5xx response, is
  /// treated as transient.
  private func isRetryable(_ standardError: String) -> Bool {
    let diagnostic = standardError.lowercased()
    let permanentFailures = [
      "not our ref",
      "couldn't find remote ref",
      "not a valid object name",
      "unadvertised object",
      "does not appear to be a git repository",
      "repository not found",
      "authentication failed",
      "could not read username",
      "could not read password",
      "permission denied",
      "invalid username or password",
      "terminal prompts disabled",
    ]
    return !permanentFailures.contains { diagnostic.contains($0) }
  }

  private func makeCommand(arguments: [String], workspace: Workspace) -> Command {
    var environment = environmentPolicy.environment()
    for key in Array(environment.keys) where key.hasPrefix("GIT_") {
      environment.removeValue(forKey: key)
    }
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_COUNT"] = "0"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["LC_ALL"] = "C"

    // Per-invocation configuration keeps checkout deterministic: no background
    // maintenance, no filesystem monitor daemon, and no implicit submodule
    // traffic. Protocol v2 is required to fetch an unadvertised commit by SHA.
    let configuration = [
      "protocol.version=2",
      "gc.auto=0",
      "core.fsmonitor=false",
      "fetch.recurseSubmodules=no",
      "advice.detachedHead=false",
    ].flatMap { ["-c", $0] }

    return Command(
      executableURL: gitExecutableURL,
      arguments: configuration + arguments,
      environment: environment,
      workingDirectoryURL: workspace.rootURL
    )
  }
}

private struct GitInvocation {
  let stage: RepositoryPreparationStage
  let arguments: [String]
}

private actor StandardErrorCollector {
  private(set) var text = ""

  func append(_ chunk: String) {
    text.append(chunk)
  }
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
