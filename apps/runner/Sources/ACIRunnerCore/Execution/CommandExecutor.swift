import Darwin
import Foundation
import Subprocess
import System

/// An infrastructure failure that prevented normal command execution.
///
/// A process that launches and returns a nonzero exit code does not throw this
/// error; it produces a ``CommandExecutionResult`` with a failed outcome.
public enum CommandExecutionError: LocalizedError, Sendable, Equatable {
  case invalidTimeout(Int)
  case launchFailed(executable: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case let .invalidTimeout(timeout):
      "Command timeout must be greater than zero; received \(timeout)."
    case let .launchFailed(executable, reason):
      "Unable to execute '\(executable)': \(reason)"
    }
  }
}

/// Executes validated commands while emitting incremental process output.
///
/// The protocol keeps ``JobExecutor`` testable and allows future execution
/// backends to preserve the same orchestration contract.
public protocol CommandExecuting: Sendable {
  /// Launches a process and waits for its output streams and termination.
  /// - Parameters:
  ///   - command: The fully resolved runtime command.
  ///   - stepID: The owning step identifier attached to log events.
  ///   - timeoutSeconds: The effective deadline for this invocation.
  ///   - onLog: An asynchronous consumer for stdout and stderr chunks.
  /// - Returns: The process's terminal result.
  /// - Throws: ``CommandExecutionError`` when the process cannot be executed.
  func execute(
    _ command: Command,
    stepID: String,
    timeoutSeconds: Int,
    onLog: @escaping LogHandler
  ) async throws -> CommandExecutionResult
}

/// The Swift `Subprocess` implementation of ``CommandExecuting``.
///
/// Every command starts in a new session so timeout and cancellation signals
/// can target the complete process group without affecting the runner. Stdout
/// and stderr are drained concurrently and decoded incrementally as UTF-8.
public struct CommandExecutor: CommandExecuting, Sendable {
  private let terminationGracePeriod: Duration

  /// Creates a process executor.
  /// - Parameter terminationGracePeriod: How long a process group may respond
  ///   to `SIGTERM` before `Subprocess` escalates to `SIGKILL`.
  public init(terminationGracePeriod: Duration = .seconds(2)) {
    self.terminationGracePeriod = terminationGracePeriod
  }

  /// Executes a command with streaming output, timeout, and cancellation.
  public func execute(
    _ command: Command,
    stepID: String,
    timeoutSeconds: Int,
    onLog: @escaping LogHandler
  ) async throws -> CommandExecutionResult {
    guard timeoutSeconds > 0 else {
      throw CommandExecutionError.invalidTimeout(timeoutSeconds)
    }

    let sequencer = LogSequencer(stepID: stepID, handler: onLog)
    let executionState = ExecutionState()
    let startedAt = Date()
    let configuration = makeConfiguration(for: command)

    // Keep the subprocess in its own task so both the explicit command timeout
    // and cancellation of the enclosing job can request the same teardown.
    let executionTask = Task {
      try await Subprocess.run(
        configuration,
        input: .none,
        output: .sequence,
        error: .sequence
      ) { execution in
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask {
            try await drain(
              execution.standardOutput,
              stream: .stdout,
              sequencer: sequencer
            )
          }
          group.addTask {
            try await drain(
              execution.standardError,
              stream: .stderr,
              sequencer: sequencer
            )
          }
          try await group.waitForAll()
        }
      }
    }

    // Reaching the deadline cancels the subprocess task. `Subprocess` then
    // runs the configured process-group teardown before the task completes.
    let timeoutTask = Task {
      do {
        try await Task.sleep(for: .seconds(timeoutSeconds))
        await executionState.markTimedOut()
        executionTask.cancel()
      } catch {
        // Cancelling the timer is the normal path when the process exits first.
      }
    }

    do {
      let result = try await withTaskCancellationHandler {
        try await executionTask.value
      } onCancel: {
        executionTask.cancel()
      }

      timeoutTask.cancel()
      _ = await timeoutTask.result

      let status = commandStatus(from: result.terminationStatus)
      let outcome: CommandOutcome
      if Task.isCancelled {
        outcome = .cancelled
      } else if await executionState.didTimeOut {
        outcome = .timedOut
      } else if result.terminationStatus.isSuccess {
        outcome = .succeeded
      } else {
        outcome = .failed
      }

      return CommandExecutionResult(
        outcome: outcome,
        exitCode: status.code,
        terminationReason: status.reason,
        startedAt: startedAt,
        finishedAt: Date()
      )
    } catch {
      timeoutTask.cancel()
      executionTask.cancel()
      _ = await timeoutTask.result
      _ = await executionTask.result

      // Cancellation can surface as `CancellationError` before a termination
      // status is available. The teardown has still completed by this point.
      let didTimeOut = await executionState.didTimeOut
      if Task.isCancelled || didTimeOut {
        return CommandExecutionResult(
          outcome: Task.isCancelled ? .cancelled : .timedOut,
          exitCode: SIGKILL,
          terminationReason: .uncaughtSignal,
          startedAt: startedAt,
          finishedAt: Date()
        )
      }

      throw CommandExecutionError.launchFailed(
        executable: command.executableURL.path,
        reason: String(describing: error)
      )
    }
  }

  private func makeConfiguration(for command: Command) -> Subprocess.Configuration {
    var platformOptions = Subprocess.PlatformOptions()
    // A new session also creates an isolated process group whose ID is the
    // child PID. This makes group-directed teardown safe for the runner.
    platformOptions.createSession = true
    platformOptions.teardownSequence = [
      .gracefulShutDown(
        toProcessGroup: true,
        allowedDurationToNextStep: terminationGracePeriod
      )
    ]

    let environment = Dictionary(
      uniqueKeysWithValues: command.environment.map { key, value in
        (Subprocess.Environment.Key(rawValue: key)!, value)
      }
    )

    return Subprocess.Configuration(
      executable: .path(FilePath(command.executableURL.path)),
      arguments: Subprocess.Arguments(command.arguments),
      environment: .custom(environment),
      workingDirectory: FilePath(command.workingDirectoryURL.path),
      platformOptions: platformOptions
    )
  }

  private func commandStatus(
    from status: Subprocess.TerminationStatus
  ) -> (code: Int32, reason: CommandTerminationReason) {
    switch status {
    case let .exited(code):
      (code, .exit)
    case let .signaled(signal):
      (signal, .uncaughtSignal)
    }
  }

  private func drain(
    _ output: SubprocessOutputSequence,
    stream: LogStream,
    sequencer: LogSequencer
  ) async throws {
    var decoder = IncrementalUTF8Decoder()

    for try await buffer in output {
      let data = Data(buffer: buffer)
      if let text = decoder.decode(data), !text.isEmpty {
        await sequencer.emit(text, stream: stream)
      }
    }

    if let text = decoder.finish(), !text.isEmpty {
      await sequencer.emit(text, stream: stream)
    }
  }
}

private actor ExecutionState {
  private(set) var didTimeOut = false

  func markTimedOut() {
    didTimeOut = true
  }
}

/// Preserves an incomplete UTF-8 scalar between arbitrary pipe buffers.
private struct IncrementalUTF8Decoder {
  private var pendingBytes: [UInt8] = []

  mutating func decode(_ data: Data) -> String? {
    pendingBytes.append(contentsOf: data)
    let completePrefixCount = completePrefixLength(in: pendingBytes)
    guard completePrefixCount > 0 else { return nil }

    let completeBytes = pendingBytes.prefix(completePrefixCount)
    pendingBytes.removeFirst(completePrefixCount)
    return String(decoding: completeBytes, as: UTF8.self)
  }

  mutating func finish() -> String? {
    guard !pendingBytes.isEmpty else { return nil }
    defer { pendingBytes.removeAll(keepingCapacity: false) }
    return String(decoding: pendingBytes, as: UTF8.self)
  }

  /// Returns a prefix that cannot end inside a potentially valid UTF-8 scalar.
  private func completePrefixLength(in bytes: [UInt8]) -> Int {
    guard let lastByte = bytes.last else { return 0 }
    if lastByte & 0b1000_0000 == 0 { return bytes.count }

    var leadIndex = bytes.count - 1
    var continuationCount = 0
    while leadIndex >= 0,
          bytes[leadIndex] & 0b1100_0000 == 0b1000_0000,
          continuationCount < 3 {
      continuationCount += 1
      leadIndex -= 1
    }

    guard leadIndex >= 0 else { return bytes.count }
    let expectedLength: Int
    switch bytes[leadIndex] {
    case 0xC2...0xDF: expectedLength = 2
    case 0xE0...0xEF: expectedLength = 3
    case 0xF0...0xF4: expectedLength = 4
    default: return bytes.count
    }

    return continuationCount + 1 < expectedLength ? leadIndex : bytes.count
  }
}
