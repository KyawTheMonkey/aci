import ACIRunnerCore
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
}

private actor LogEventCollector {
  private(set) var events: [LogEvent] = []

  func append(_ event: LogEvent) {
    events.append(event)
  }
}
