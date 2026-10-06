import Foundation

/// The isolated filesystem root assigned to one job attempt.
public struct Workspace: Sendable, Equatable {
  /// The canonical directory beneath which all job-relative paths must remain.
  public let rootURL: URL

  /// Creates a workspace value for an already prepared directory.
  public init(rootURL: URL) {
    self.rootURL = rootURL
  }
}
