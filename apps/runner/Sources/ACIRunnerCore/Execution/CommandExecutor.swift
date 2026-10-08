import Darwin
import Foundation
import Subprocess
import System

/// An infrastructure failure that prevented normal command execution.
///
/// A process that launches and returns a nonzero exit code does not throw this
/// error; it produces a ``CommandExecutionResult`` with a failed outcome.
///
/// ``executableUnavailable`` and ``workingDirectoryUnavailable`` describe
/// problems with the values a job supplied. ``JobExecutor`` treats them as
/// step failures for user commands so a workflow typo is not retried as a
/// runner fault, while runner-owned tools such as Git still report them as
/// infrastructure failures.
public enum CommandExecutionError: LocalizedError, Sendable, Equatable {
  case invalidTimeout(Int)
  case executableUnavailable(path: String)
  case workingDirectoryUnavailable(path: String)
  case launchFailed(executable: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case let .invalidTimeout(timeout):
      "Command timeout must be greater than zero; received \(timeout)."
    case let .executableUnavailable(path):
      "Executable '\(path)' does not exist or is not executable."
    case let .workingDirectoryUnavailable(path):
      "Working directory '\(path)' does not exist or is not a directory."
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
    // and cancellation of the enclosing job can request the same teardown. The
    // task records completion itself so no interruption can be attributed to a
    // process that had already exited.
    let executionTask = Task {
      let result = try await Subprocess.run(
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
      return (status: result.terminationStatus, interruption: executionState.finish())
    }

    // Reaching the deadline cancels the subprocess task. `Subprocess` then
    // runs the configured process-group teardown before the task completes.
    let timeoutTask = Task {
      guard (try? await Task.sleep(for: .seconds(timeoutSeconds))) != nil else {
        // Cancelling the timer is the normal path when the process exits first.
        return
      }
      if executionState.interrupt(.timedOut) {
        executionTask.cancel()
      }
    }
    defer { timeoutTask.cancel() }

    do {
      let (terminationStatus, interruption) = try await withTaskCancellationHandler {
        try await executionTask.value
      } onCancel: {
        if executionState.interrupt(.cancelled) {
          executionTask.cancel()
        }
      }

      let status = commandStatus(from: terminationStatus)
      let outcome: CommandOutcome
      switch interruption {
      case .cancelled:
        outcome = .cancelled
      case .timedOut:
        outcome = .timedOut
      case .none:
        outcome = terminationStatus.isSuccess ? .succeeded : .failed
      }

      return CommandExecutionResult(
        outcome: outcome,
        exitCode: status.code,
        terminationReason: status.reason,
        startedAt: startedAt,
        finishedAt: Date()
      )
    } catch {
      executionTask.cancel()
      _ = await executionTask.result

      // Cancellation can surface as `CancellationError` before a termination
      // status is available. The teardown has still completed by this point,
      // and `SIGKILL` is the only status the teardown sequence guarantees.
      let interruption = executionState.finish()
      switch interruption {
      case .cancelled, .timedOut:
        return CommandExecutionResult(
          outcome: interruption == .cancelled ? .cancelled : .timedOut,
          exitCode: SIGKILL,
          terminationReason: .uncaughtSignal,
          startedAt: startedAt,
          finishedAt: Date()
        )
      case .none:
        throw classifyLaunchError(error, for: command)
      }
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

  private func classifyLaunchError(_ error: any Error, for command: Command) -> CommandExecutionError {
    if let subprocessError = error as? SubprocessError {
      switch subprocessError.code {
      case .executableNotFound:
        return .executableUnavailable(path: command.executableURL.path)
      case .failedToChangeWorkingDirectory:
        return .workingDirectoryUnavailable(path: command.workingDirectoryURL.path)
      default:
        break
      }
    }

    return .launchFailed(
      executable: command.executableURL.path,
      reason: String(describing: error)
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

    do {
      for try await buffer in output {
        if let text = decoder.decode(buffer), !text.isEmpty {
          await sequencer.emit(text, stream: stream)
        }
      }
    } catch is CancellationError {
      // Teardown is already in progress. Stop reading so the real termination
      // status can still be reported instead of failing the whole body.
    }

    if let text = decoder.finish(), !text.isEmpty {
      await sequencer.emit(text, stream: stream)
    }
  }
}

/// Records, exactly once, why a command stopped before its process exited.
///
/// Both the deadline timer and caller cancellation race against natural
/// process exit. Serializing those transitions under one lock guarantees that
/// a process which already finished is never reported as interrupted.
private final class ExecutionState: @unchecked Sendable {
  enum Interruption: Equatable {
    case none
    case timedOut
    case cancelled
  }

  private let lock = NSLock()
  private var interruption: Interruption = .none
  private var hasFinished = false

  /// Returns `true` when this call is the first interruption of a running command.
  func interrupt(_ reason: Interruption) -> Bool {
    lock.withLock {
      guard !hasFinished, interruption == .none else { return false }
      interruption = reason
      return true
    }
  }

  /// Marks the command finished and returns the interruption that preceded it.
  func finish() -> Interruption {
    lock.withLock {
      hasFinished = true
      return interruption
    }
  }
}

/// Preserves an incomplete UTF-8 scalar between arbitrary pipe buffers.
private struct IncrementalUTF8Decoder {
  private var pendingBytes: [UInt8] = []

  mutating func decode(_ buffer: SubprocessOutputSequence.Buffer) -> String? {
    buffer.withUnsafeBytes { bytes -> String? in
      // Fast path: nothing is pending and the chunk ends on a scalar boundary,
      // so it can be decoded without copying through the pending buffer.
      if pendingBytes.isEmpty {
        let completeCount = completePrefixLength(in: bytes)
        if completeCount == bytes.count {
          return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
      }

      pendingBytes.append(contentsOf: bytes)
      let completePrefixCount = pendingBytes.withUnsafeBytes(completePrefixLength)
      guard completePrefixCount > 0 else { return nil }

      let text = String(decoding: pendingBytes[..<completePrefixCount], as: UTF8.self)
      pendingBytes.removeFirst(completePrefixCount)
      return text
    }
  }

  mutating func finish() -> String? {
    guard !pendingBytes.isEmpty else { return nil }
    defer { pendingBytes.removeAll(keepingCapacity: false) }
    return String(decoding: pendingBytes, as: UTF8.self)
  }

  /// Returns a prefix that cannot end inside a potentially valid UTF-8 scalar.
  private func completePrefixLength(in bytes: UnsafeRawBufferPointer) -> Int {
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
