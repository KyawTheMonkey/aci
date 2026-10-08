import ACIRunnerCore
import Foundation
import Testing

@Suite("Git repository preparer", .serialized)
struct GitRepositoryPreparerTests {
  @Test("Checks out the requested commit instead of the branch tip")
  func checksOutExactCommit() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("source", isDirectory: true)
    let checkout = base.appendingPathComponent("checkout", isDirectory: true)
    let commits = try makeSourceRepository(at: source)
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)

    try await GitRepositoryPreparer().prepare(
      RepositorySpecification(
        cloneURL: source,
        commitSHA: commits.first
      ),
      in: Workspace(rootURL: checkout),
      deadline: Date().addingTimeInterval(10),
      onLog: { _ in }
    )

    let checkedOutSHA = try runGit(["rev-parse", "HEAD"], in: checkout)
    let contents = try String(
      contentsOf: checkout.appendingPathComponent("version.txt"),
      encoding: .utf8
    )

    #expect(checkedOutSHA == commits.first)
    #expect(checkedOutSHA != commits.second)
    #expect(contents == "first\n")
  }

  @Test("Reports the Git stage for an unknown commit")
  func rejectsUnknownCommit() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("source", isDirectory: true)
    let checkout = base.appendingPathComponent("checkout", isDirectory: true)
    _ = try makeSourceRepository(at: source)
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    let missingSHA = String(repeating: "f", count: 40)

    do {
      try await GitRepositoryPreparer().prepare(
        RepositorySpecification(cloneURL: source, commitSHA: missingSHA),
        in: Workspace(rootURL: checkout),
        deadline: Date().addingTimeInterval(10),
        onLog: { _ in }
      )
      Issue.record("Expected an unknown commit to fail.")
    } catch let error as RepositoryPreparationError {
      guard case let .commandFailed(stage, result) = error else {
        Issue.record("Expected a Git command failure; received \(error).")
        return
      }

      #expect(stage == .fetch)
      #expect(result.outcome == .failed)
      #expect(result.exitCode != 0)
    }
  }

  @Test("Retries transient fetch failures and then checks out")
  func retriesTransientFetchFailures() async throws {
    let success = makeCommandResult(outcome: .succeeded, exitCode: 0)
    let transient = makeCommandResult(outcome: .failed, exitCode: 128)
    let commandExecutor = ScriptedCommandExecutor(responses: [
      .result(success),
      .result(transient, stderr: "fatal: unable to access 'https://github.com/x/y.git/': Could not resolve host\n"),
      .result(transient, stderr: "error: RPC failed; curl 56 Recv failure\n"),
      .result(success),
      .result(success),
    ])
    let preparer = GitRepositoryPreparer(
      commandExecutor: commandExecutor,
      fetchRetryDelays: [.zero, .zero]
    )
    let collector = LogCollector()

    try await preparer.prepare(
      makeRepository(),
      in: Workspace(rootURL: FileManager.default.temporaryDirectory),
      deadline: Date().addingTimeInterval(60),
      onLog: { event in await collector.append(event) }
    )

    let subcommands = await commandExecutor.commands.map { command in
      command.arguments.first { !$0.hasPrefix("-") && !$0.contains("=") } ?? ""
    }
    #expect(subcommands == ["init", "fetch", "fetch", "fetch", "checkout"])
    let retryNotices = await collector.events.filter { $0.text.contains("retrying") }
    #expect(retryNotices.count == 2)
    #expect(await commandExecutor.commands.allSatisfy { $0.environment["GIT_TERMINAL_PROMPT"] == "0" })
  }

  @Test("Does not retry fetches that can never succeed")
  func doesNotRetryPermanentFailures() async throws {
    let commandExecutor = ScriptedCommandExecutor(responses: [
      .result(makeCommandResult(outcome: .succeeded, exitCode: 0)),
      .result(
        makeCommandResult(outcome: .failed, exitCode: 128),
        stderr: "fatal: remote error: upload-pack: not our ref ffff\n"
      ),
      .result(makeCommandResult(outcome: .succeeded, exitCode: 0)),
    ])
    let preparer = GitRepositoryPreparer(
      commandExecutor: commandExecutor,
      fetchRetryDelays: [.zero, .zero]
    )

    await #expect(throws: RepositoryPreparationError.self) {
      try await preparer.prepare(
        makeRepository(),
        in: Workspace(rootURL: FileManager.default.temporaryDirectory),
        deadline: Date().addingTimeInterval(60),
        onLog: { _ in }
      )
    }

    #expect(await commandExecutor.commands.count == 2)
  }

  @Test("Does not launch Git after the job deadline")
  func respectsJobDeadline() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }

    await #expect(throws: RepositoryPreparationError.self) {
      try await GitRepositoryPreparer().prepare(
        RepositorySpecification(
          cloneURL: base,
          commitSHA: String(repeating: "a", count: 40)
        ),
        in: Workspace(rootURL: base),
        deadline: Date().addingTimeInterval(-1),
        onLog: { _ in }
      )
    }

    #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent(".git").path))
  }
}

private actor LogCollector {
  private(set) var events: [LogEvent] = []

  func append(_ event: LogEvent) {
    events.append(event)
  }
}

private func makeSourceRepository(at url: URL) throws -> (first: String, second: String) {
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  try runGit(["init", "--quiet"], in: url)
  try runGit(["config", "user.name", "ACI Tests"], in: url)
  try runGit(["config", "user.email", "runner-tests@aci.invalid"], in: url)

  let versionFile = url.appendingPathComponent("version.txt")
  try Data("first\n".utf8).write(to: versionFile)
  try runGit(["add", "version.txt"], in: url)
  try runGit(["commit", "--quiet", "-m", "first"], in: url)
  let first = try runGit(["rev-parse", "HEAD"], in: url)

  try Data("second\n".utf8).write(to: versionFile)
  try runGit(["add", "version.txt"], in: url)
  try runGit(["commit", "--quiet", "-m", "second"], in: url)
  let second = try runGit(["rev-parse", "HEAD"], in: url)

  return (first, second)
}

@discardableResult
private func runGit(_ arguments: [String], in directory: URL) throws -> String {
  let process = Process()
  let stdout = Pipe()
  let stderr = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = arguments
  process.currentDirectoryURL = directory
  process.standardOutput = stdout
  process.standardError = stderr

  try process.run()
  process.waitUntilExit()

  let output = stdout.fileHandleForReading.readDataToEndOfFile()
  let diagnostic = stderr.fileHandleForReading.readDataToEndOfFile()
  guard process.terminationStatus == 0 else {
    throw GitFixtureError.commandFailed(
      arguments: arguments,
      diagnostic: String(decoding: diagnostic, as: UTF8.self)
    )
  }

  return String(decoding: output, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

private enum GitFixtureError: LocalizedError {
  case commandFailed(arguments: [String], diagnostic: String)

  var errorDescription: String? {
    switch self {
    case let .commandFailed(arguments, diagnostic):
      "Git fixture command failed: \(arguments.joined(separator: " "))\n\(diagnostic)"
    }
  }
}
