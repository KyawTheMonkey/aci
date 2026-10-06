import ACIRunnerCore
import Darwin
import Foundation
import Testing

@Suite("Command executor", .serialized)
struct CommandExecutorTests {
  @Test("Returns success and failure exit codes", arguments: [
    ("/usr/bin/true", CommandOutcome.succeeded),
    ("/usr/bin/false", CommandOutcome.failed),
  ])
  func exitCodes(executable: String, expected: CommandOutcome) async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let command = Command(
      executableURL: URL(fileURLWithPath: executable),
      arguments: [],
      environment: ProcessInfo.processInfo.environment,
      workingDirectoryURL: directory
    )

    let result = try await CommandExecutor().execute(
      command,
      stepID: "exit",
      timeoutSeconds: 5,
      onLog: { _ in }
    )

    #expect(result.outcome == expected)
  }

  @Test("Streams stdout and stderr with increasing sequence numbers")
  func streamsOutput() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let collector = LogEventCollector()
    let command = Command(
      executableURL: URL(fileURLWithPath: "/bin/zsh"),
      arguments: ["-c", "printf 'output'; printf 'error' >&2"],
      environment: ProcessInfo.processInfo.environment,
      workingDirectoryURL: directory
    )

    let result = try await CommandExecutor().execute(
      command,
      stepID: "logs",
      timeoutSeconds: 5
    ) { event in
      await collector.append(event)
    }
    let events = await collector.events

    #expect(result.outcome == .succeeded)
    #expect(events.map(\.sequence) == Array(0..<UInt64(events.count)))
    #expect(events.filter { $0.stream == .stdout }.map(\.text).joined() == "output")
    #expect(events.filter { $0.stream == .stderr }.map(\.text).joined() == "error")
  }

  @Test("Times out a long-running process")
  func timeout() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let command = Command(
      executableURL: URL(fileURLWithPath: "/bin/sleep"),
      arguments: ["5"],
      environment: ProcessInfo.processInfo.environment,
      workingDirectoryURL: directory
    )

    let result = try await CommandExecutor().execute(
      command,
      stepID: "timeout",
      timeoutSeconds: 1,
      onLog: { _ in }
    )

    #expect(result.outcome == .timedOut)
  }

  @Test("Cancellation terminates a running process")
  func cancellation() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let command = Command(
      executableURL: URL(fileURLWithPath: "/bin/sleep"),
      arguments: ["30"],
      environment: ProcessInfo.processInfo.environment,
      workingDirectoryURL: directory
    )
    let execution = Task {
      try await CommandExecutor().execute(
        command,
        stepID: "cancel",
        timeoutSeconds: 60,
        onLog: { _ in }
      )
    }

    try await Task.sleep(for: .milliseconds(100))
    execution.cancel()
    let result = try await execution.value

    #expect(result.outcome == .cancelled)
  }

  @Test("Timeout terminates the complete process group")
  func timeoutTerminatesProcessGroup() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("processes.txt")
    let command = makeStubbornProcessTreeCommand(pidFile: pidFile, directory: directory)
    let executor = CommandExecutor(terminationGracePeriod: .milliseconds(100))

    let result = try await executor.execute(
      command,
      stepID: "process-tree-timeout",
      timeoutSeconds: 1,
      onLog: { _ in }
    )
    let processIDs = try readProcessIDs(from: pidFile)
    defer { terminateProcessGroupForTest(processIDs.root) }

    #expect(result.outcome == .timedOut)
    #expect(result.terminationReason == .uncaughtSignal)
    #expect(result.exitCode == SIGKILL)
    #expect(await processHasExited(processIDs.root))
    #expect(await processHasExited(processIDs.child))
  }

  @Test("A SIGTERM-resistant command is force killed")
  func escalatesToSIGKILL() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let command = Command(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "trap '' TERM; exec /bin/sleep 30"],
      environment: ProcessInfo.processInfo.environment,
      workingDirectoryURL: directory
    )

    let result = try await CommandExecutor(
      terminationGracePeriod: .milliseconds(100)
    ).execute(
      command,
      stepID: "force-kill",
      timeoutSeconds: 1,
      onLog: { _ in }
    )

    #expect(result.outcome == .timedOut)
    #expect(result.terminationReason == .uncaughtSignal)
    #expect(result.exitCode == SIGKILL)
  }

  @Test("Cancellation terminates descendants in the process group")
  func cancellationTerminatesProcessGroup() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("processes.txt")
    let command = makeStubbornProcessTreeCommand(pidFile: pidFile, directory: directory)
    let executor = CommandExecutor(terminationGracePeriod: .milliseconds(100))
    let execution = Task {
      try await executor.execute(
        command,
        stepID: "process-tree-cancellation",
        timeoutSeconds: 5,
        onLog: { _ in }
      )
    }

    try await waitForFile(at: pidFile)
    let processIDs = try readProcessIDs(from: pidFile)
    defer { terminateProcessGroupForTest(processIDs.root) }
    execution.cancel()
    let result = try await execution.value

    #expect(result.outcome == .cancelled)
    #expect(await processHasExited(processIDs.root))
    #expect(await processHasExited(processIDs.child))
  }

  @Test("A child retaining inherited pipes does not block parent completion")
  func inheritedPipeDoesNotHang() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("child.txt")
    let command = Command(
      executableURL: URL(fileURLWithPath: "/bin/zsh"),
      arguments: [
        "-c",
        "/bin/sleep 30 & child=$!; echo $child > \"$1\"",
        "aci-test",
        pidFile.path,
      ],
      environment: ProcessInfo.processInfo.environment,
      workingDirectoryURL: directory
    )
    let startedAt = ContinuousClock.now

    let result = try await CommandExecutor().execute(
      command,
      stepID: "inherited-pipe",
      timeoutSeconds: 5,
      onLog: { _ in }
    )
    let elapsed = ContinuousClock.now - startedAt
    let childPID = try #require(
      pid_t(
        String(contentsOf: pidFile, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      )
    )
    defer { Darwin.kill(childPID, SIGKILL) }

    #expect(result.outcome == .succeeded)
    #expect(elapsed < .seconds(2))
  }

  @Test("UTF-8 scalars remain intact across separate writes")
  func preservesSplitUTF8Scalar() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let collector = LogEventCollector()
    let command = Command(
      executableURL: URL(fileURLWithPath: "/bin/zsh"),
      arguments: ["-c", "printf '\\360\\237'; sleep 0.1; printf '\\230\\200'"],
      environment: ProcessInfo.processInfo.environment,
      workingDirectoryURL: directory
    )

    let result = try await CommandExecutor().execute(
      command,
      stepID: "utf8",
      timeoutSeconds: 5
    ) { event in
      await collector.append(event)
    }
    let text = await collector.events.map(\.text).joined()

    #expect(result.outcome == .succeeded)
    #expect(text == "😀")
  }

  @Test("Large stdout and stderr streams are drained concurrently")
  func drainsConcurrentOutput() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let collector = LogEventCollector()
    let command = Command(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: [
        "-c",
        "i=0; while [ $i -lt 20000 ]; do printf o; printf e >&2; i=$((i + 1)); done",
      ],
      environment: ProcessInfo.processInfo.environment,
      workingDirectoryURL: directory
    )

    let result = try await CommandExecutor().execute(
      command,
      stepID: "concurrent-output",
      timeoutSeconds: 5
    ) { event in
      await collector.append(event)
    }
    let events = await collector.events
    let stdout = events.filter { $0.stream == .stdout }.map(\.text).joined()
    let stderr = events.filter { $0.stream == .stderr }.map(\.text).joined()

    #expect(result.outcome == .succeeded)
    #expect(stdout.count == 20_000)
    #expect(stderr.count == 20_000)
  }
}

private actor LogEventCollector {
  private(set) var events: [LogEvent] = []

  func append(_ event: LogEvent) {
    events.append(event)
  }
}

private func makeStubbornProcessTreeCommand(pidFile: URL, directory: URL) -> Command {
  Command(
    executableURL: URL(fileURLWithPath: "/bin/sh"),
    arguments: [
      "-c",
      "trap '' TERM; /bin/sleep 30 & child=$!; echo \"$$ $child\" > \"$1\"; wait $child",
      "aci-test",
      pidFile.path,
    ],
    environment: ProcessInfo.processInfo.environment,
    workingDirectoryURL: directory
  )
}

private func readProcessIDs(from file: URL) throws -> (root: pid_t, child: pid_t) {
  let fields = try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isWhitespace)
  let root = try #require(fields.first.flatMap { pid_t($0) })
  let child = try #require(fields.dropFirst().first.flatMap { pid_t($0) })
  return (root, child)
}

private func waitForFile(at url: URL) async throws {
  for _ in 0..<100 {
    if FileManager.default.fileExists(atPath: url.path) { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  throw TestSupportError.timedOutWaitingForFile(url.path)
}

private func processHasExited(_ processID: pid_t) async -> Bool {
  for _ in 0..<100 {
    errno = 0
    if Darwin.kill(processID, 0) == -1, errno == ESRCH { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return false
}

private func terminateProcessGroupForTest(_ processGroupID: pid_t) {
  Darwin.kill(-processGroupID, SIGKILL)
}

private enum TestSupportError: LocalizedError {
  case timedOutWaitingForFile(String)

  var errorDescription: String? {
    switch self {
    case let .timedOutWaitingForFile(path):
      "Timed out waiting for process fixture at \(path)."
    }
  }
}
