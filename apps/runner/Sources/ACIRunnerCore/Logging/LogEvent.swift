import Foundation

/// Identifies the subprocess pipe that produced a log event.
public enum LogStream: String, Codable, Sendable, Equatable {
  case stdout
  case stderr
}

/// An ordered chunk of output produced by a job step.
public struct LogEvent: Codable, Sendable, Equatable {
  /// A monotonically increasing number within one job attempt.
  public let sequence: UInt64
  /// The step that produced the output.
  public let stepID: String
  /// The originating standard stream.
  public let stream: LogStream
  /// When the runner observed the output.
  public let timestamp: Date
  /// The UTF-8-decoded output chunk.
  public let text: String

  /// Creates a structured log event.
  public init(
    sequence: UInt64,
    stepID: String,
    stream: LogStream,
    timestamp: Date,
    text: String
  ) {
    self.sequence = sequence
    self.stepID = stepID
    self.stream = stream
    self.timestamp = timestamp
    self.text = text
  }
}

/// An asynchronous destination for log events.
public typealias LogHandler = @Sendable (LogEvent) async -> Void

/// Serializes stdout and stderr callbacks into one monotonic command stream.
actor LogSequencer {
  private var nextSequence: UInt64 = 0
  private let stepID: String
  private let handler: LogHandler

  init(stepID: String, handler: @escaping LogHandler) {
    self.stepID = stepID
    self.handler = handler
  }

  func emit(_ data: Data, stream: LogStream) async {
    guard !data.isEmpty else { return }

    let event = LogEvent(
      sequence: nextSequence,
      stepID: stepID,
      stream: stream,
      timestamp: Date(),
      text: String(decoding: data, as: UTF8.self)
    )
    nextSequence += 1
    await handler(event)
  }
}
