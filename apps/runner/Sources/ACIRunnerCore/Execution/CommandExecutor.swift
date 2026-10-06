import Darwin
import Foundation

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
      "Unable to launch '\(executable)': \(reason)"
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
  /// - Throws: ``CommandExecutionError`` when the process cannot be launched.
  func execute(
    _ command: Command,
    stepID: String,
    timeoutSeconds: Int,
    onLog: @escaping LogHandler
  ) async throws -> CommandExecutionResult
}

/// The Foundation `Process` implementation of ``CommandExecuting``.
///
/// Stdout and stderr are drained concurrently to prevent a subprocess from
/// blocking on a full pipe. Cancellation is bridged from Swift tasks to the
/// operating-system process, with a delayed `SIGKILL` fallback.
public struct CommandExecutor: CommandExecuting, Sendable {
  /// Creates a process executor.
  public init() {}

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

    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let sequencer = LogSequencer(stepID: stepID, handler: onLog)
    let terminationController = ProcessTerminationController()
    let executionState = ExecutionState()
    let startedAt = Date()

    process.executableURL = command.executableURL
    process.arguments = command.arguments
    process.environment = command.environment
    process.currentDirectoryURL = command.workingDirectoryURL
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Begin draining both pipes before launch so a fast or noisy subprocess
    // cannot fill a pipe before the reader is ready.
    let stdoutReader = makeReader(
      handle: stdoutPipe.fileHandleForReading,
      stream: .stdout,
      sequencer: sequencer
    )
    let stderrReader = makeReader(
      handle: stderrPipe.fileHandleForReading,
      stream: .stderr,
      sequencer: sequencer
    )

    // Install the termination handler before `run()` to avoid missing the exit
    // of very short-lived commands such as `/usr/bin/true`.
    let processTask = Task<ProcessExit, any Error> {
      try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { terminatedProcess in
          let reason: CommandTerminationReason = switch terminatedProcess.terminationReason {
          case .exit: .exit
          case .uncaughtSignal: .uncaughtSignal
          @unknown default: .uncaughtSignal
          }

          continuation.resume(
            returning: ProcessExit(
              status: terminatedProcess.terminationStatus,
              reason: reason
            )
          )
        }

        do {
          try process.run()
          terminationController.attach(process)
          try? stdoutPipe.fileHandleForWriting.close()
          try? stderrPipe.fileHandleForWriting.close()
        } catch {
          try? stdoutPipe.fileHandleForWriting.close()
          try? stderrPipe.fileHandleForWriting.close()
          continuation.resume(
            throwing: CommandExecutionError.launchFailed(
              executable: command.executableURL.path,
              reason: error.localizedDescription
            )
          )
        }
      }
    }

    // The timeout owns process termination; cancelling this task is the normal
    // path when the subprocess completes before its deadline.
    let timeoutTask = Task {
      do {
        try await Task.sleep(for: .seconds(timeoutSeconds))
        await executionState.markTimedOut()
        terminationController.requestTermination()
      } catch {
        // Cancelling the timer is the normal path when the process exits first.
      }
    }

    do {
      let processExit = try await withTaskCancellationHandler {
        try await processTask.value
      } onCancel: {
        terminationController.requestTermination()
      }

      timeoutTask.cancel()
      _ = await timeoutTask.result
      _ = await stdoutReader.result
      _ = await stderrReader.result

      let outcome: CommandOutcome
      if Task.isCancelled {
        outcome = .cancelled
      } else if await executionState.didTimeOut {
        outcome = .timedOut
      } else if processExit.status == 0 {
        outcome = .succeeded
      } else {
        outcome = .failed
      }

      return CommandExecutionResult(
        outcome: outcome,
        exitCode: processExit.status,
        terminationReason: processExit.reason,
        startedAt: startedAt,
        finishedAt: Date()
      )
    } catch {
      timeoutTask.cancel()
      terminationController.requestTermination()
      try? stdoutPipe.fileHandleForReading.close()
      try? stderrPipe.fileHandleForReading.close()
      _ = await stdoutReader.result
      _ = await stderrReader.result
      throw error
    }
  }

  private func makeReader(
    handle: FileHandle,
    stream: LogStream,
    sequencer: LogSequencer
  ) -> Task<Void, Never> {
    Task.detached(priority: .utility) {
      do {
        while !Task.isCancelled,
              let data = try handle.read(upToCount: 4_096),
              !data.isEmpty {
          await sequencer.emit(data, stream: stream)
        }
      } catch {
        // Closing the handle during cancellation is an expected shutdown path.
      }
    }
  }
}

private struct ProcessExit: Sendable {
  let status: Int32
  let reason: CommandTerminationReason
}

private actor ExecutionState {
  private(set) var didTimeOut = false

  func markTimedOut() {
    didTimeOut = true
  }
}

/// Coordinates termination requests that may arrive before or after launch.
///
/// `Foundation.Process` is shared with synchronous cancellation callbacks, so
/// the small amount of mutable attachment state is protected by a lock.
private final class ProcessTerminationController: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var terminationRequested = false

  func attach(_ process: Process) {
    lock.lock()
    self.process = process
    let shouldTerminate = terminationRequested
    lock.unlock()

    if shouldTerminate {
      terminate(process)
    }
  }

  func requestTermination() {
    lock.lock()
    terminationRequested = true
    let process = process
    lock.unlock()

    if let process {
      terminate(process)
    }
  }

  private func terminate(_ process: Process) {
    guard process.isRunning else { return }

    process.terminate()
    let pid = process.processIdentifier

    // A command may ignore SIGTERM. Escalate after a grace period so the job
    // cannot keep a runner occupied forever.
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
      if process.isRunning {
        Darwin.kill(pid, SIGKILL)
      }
    }
  }
}
