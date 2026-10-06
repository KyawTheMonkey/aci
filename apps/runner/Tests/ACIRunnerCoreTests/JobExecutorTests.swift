import ACIRunnerCore
import Foundation
import Testing

@Suite("Job executor")
struct JobExecutorTests {
  @Test("Runs steps in order")
  func runsInOrder() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let commandExecutor = StubCommandExecutor(responses: [
      .result(makeCommandResult(outcome: .succeeded, exitCode: 0)),
      .result(makeCommandResult(outcome: .succeeded, exitCode: 0)),
    ])
    let executor = JobExecutor(
      workspaceManager: try WorkspaceManager(baseDirectory: base),
      commandExecutor: commandExecutor
    )
    let job = makeJob(steps: [makeStep(id: "first"), makeStep(id: "second")])

    let result = try await executor.execute(job)

    #expect(result.outcome == .succeeded)
    #expect(result.stepResults.map(\.stepID) == ["first", "second"])
    #expect(await commandExecutor.executedStepIDs == ["first", "second"])
  }

  @Test("Prepares the repository before command steps")
  func preparesRepositoryFirst() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let commandExecutor = StubCommandExecutor(responses: [
      .result(makeCommandResult(outcome: .succeeded, exitCode: 0))
    ])
    let repositoryPreparer = StubRepositoryPreparer(response: .success)
    let executor = JobExecutor(
      workspaceManager: try WorkspaceManager(baseDirectory: base),
      commandExecutor: commandExecutor,
      repositoryPreparer: repositoryPreparer
    )
    let repository = makeRepository()

    let result = try await executor.execute(makeJob(repository: repository))

    #expect(result.outcome == .succeeded)
    #expect(result.stepResults.map(\.stepID) == ["checkout", "test"])
    #expect(await repositoryPreparer.preparedRepositories == [repository])
    #expect(await commandExecutor.executedStepIDs == ["test"])
  }

  @Test("A checkout failure prevents command steps from running")
  func checkoutFailureStopsJob() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let commandExecutor = StubCommandExecutor(responses: [
      .result(makeCommandResult(outcome: .succeeded, exitCode: 0))
    ])
    let checkoutResult = makeCommandResult(outcome: .failed, exitCode: 128)
    let repositoryPreparer = StubRepositoryPreparer(
      response: .failure(
        .commandFailed(stage: .fetch, result: checkoutResult)
      )
    )
    let executor = JobExecutor(
      workspaceManager: try WorkspaceManager(baseDirectory: base),
      commandExecutor: commandExecutor,
      repositoryPreparer: repositoryPreparer
    )

    let result = try await executor.execute(
      makeJob(repository: makeRepository())
    )

    #expect(result.outcome == .failed)
    #expect(result.stepResults.count == 1)
    #expect(result.stepResults.first?.stepID == "checkout")
    #expect(result.stepResults.first?.exitCode == 128)
    #expect(await commandExecutor.executedStepIDs.isEmpty)
  }

  @Test("Stops after a disallowed failure")
  func stopsAfterFailure() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let commandExecutor = StubCommandExecutor(responses: [
      .result(makeCommandResult(outcome: .failed, exitCode: 1)),
      .result(makeCommandResult(outcome: .succeeded, exitCode: 0)),
    ])
    let executor = JobExecutor(
      workspaceManager: try WorkspaceManager(baseDirectory: base),
      commandExecutor: commandExecutor
    )
    let job = makeJob(steps: [makeStep(id: "first"), makeStep(id: "second")])

    let result = try await executor.execute(job)

    #expect(result.outcome == .failed)
    #expect(await commandExecutor.executedStepIDs == ["first"])
  }

  @Test("Continues after an allowed failure")
  func continuesAfterAllowedFailure() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let commandExecutor = StubCommandExecutor(responses: [
      .result(makeCommandResult(outcome: .failed, exitCode: 1)),
      .result(makeCommandResult(outcome: .succeeded, exitCode: 0)),
    ])
    let executor = JobExecutor(
      workspaceManager: try WorkspaceManager(baseDirectory: base),
      commandExecutor: commandExecutor
    )
    let job = makeJob(steps: [
      makeStep(id: "first", continueOnError: true),
      makeStep(id: "second"),
    ])

    let result = try await executor.execute(job)

    #expect(result.outcome == .succeeded)
    #expect(result.stepResults.map(\.outcome) == [.failed, .succeeded])
    #expect(await commandExecutor.executedStepIDs == ["first", "second"])
  }

  @Test("Classifies launch errors as infrastructure failures")
  func infrastructureFailure() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let commandExecutor = StubCommandExecutor(responses: [
      .failure("Executable disappeared")
    ])
    let executor = JobExecutor(
      workspaceManager: try WorkspaceManager(baseDirectory: base),
      commandExecutor: commandExecutor
    )

    let result = try await executor.execute(makeJob())

    #expect(result.outcome == .infrastructureFailed)
    #expect(result.stepResults.first?.outcome == .infrastructureFailed)
  }

  @Test("Log sequence numbers remain monotonic across steps")
  func jobLogSequence() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let commandExecutor = StubCommandExecutor(responses: [
      .result(makeCommandResult(outcome: .succeeded, exitCode: 0)),
      .result(makeCommandResult(outcome: .succeeded, exitCode: 0)),
    ])
    let executor = JobExecutor(
      workspaceManager: try WorkspaceManager(baseDirectory: base),
      commandExecutor: commandExecutor
    )
    let collector = JobLogCollector()

    _ = try await executor.execute(
      makeJob(steps: [makeStep(id: "first"), makeStep(id: "second")])
    ) { event in
      await collector.append(event)
    }
    let events = await collector.events

    #expect(events.map(\.sequence) == [0, 1])
    #expect(events.map(\.stepID) == ["first", "second"])
  }
}

private enum StubResponse: Sendable {
  case result(CommandExecutionResult)
  case failure(String)
}

private struct StubError: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor StubCommandExecutor: CommandExecuting {
  private var responses: [StubResponse]
  private(set) var executedStepIDs: [String] = []

  init(responses: [StubResponse]) {
    self.responses = responses
  }

  func execute(
    _ command: Command,
    stepID: String,
    timeoutSeconds: Int,
    onLog: @escaping LogHandler
  ) async throws -> CommandExecutionResult {
    executedStepIDs.append(stepID)
    await onLog(
      LogEvent(
        sequence: 0,
        stepID: stepID,
        stream: .stdout,
        timestamp: Date(),
        text: stepID
      )
    )
    guard !responses.isEmpty else {
      throw StubError(message: "No stub response was configured.")
    }

    switch responses.removeFirst() {
    case let .result(result):
      return result
    case let .failure(message):
      throw StubError(message: message)
    }
  }
}

private enum StubRepositoryResponse: Sendable {
  case success
  case failure(RepositoryPreparationError)
}

private actor StubRepositoryPreparer: RepositoryPreparing {
  private let response: StubRepositoryResponse
  private(set) var preparedRepositories: [RepositorySpecification] = []

  init(response: StubRepositoryResponse) {
    self.response = response
  }

  func prepare(
    _ repository: RepositorySpecification,
    in workspace: Workspace,
    deadline: Date,
    onLog: @escaping LogHandler
  ) async throws {
    preparedRepositories.append(repository)
    await onLog(
      LogEvent(
        sequence: 0,
        stepID: GitRepositoryPreparer.stepID,
        stream: .stdout,
        timestamp: Date(),
        text: "checkout"
      )
    )

    if case let .failure(error) = response {
      throw error
    }
  }
}

private actor JobLogCollector {
  private(set) var events: [LogEvent] = []

  func append(_ event: LogEvent) {
    events.append(event)
  }
}
