import Foundation

/// A failure to create, resolve, or safely remove a job workspace.
public enum WorkspaceError: LocalizedError, Sendable, Equatable {
  case unsafeBaseDirectory(URL)
  case unsafePath(String)
  case pathEscapesWorkspace(String)
  case workspaceOutsideBase(URL)

  public var errorDescription: String? {
    switch self {
    case let .unsafeBaseDirectory(url):
      "Workspace base directory must be an absolute file URL: \(url.path)."
    case let .unsafePath(path):
      "Workspace path must be relative and must not contain parent traversal: \(path)."
    case let .pathEscapesWorkspace(path):
      "Resolved path escapes the job workspace: \(path)."
    case let .workspaceOutsideBase(url):
      "Refusing to remove a directory outside the configured workspace base: \(url.path)."
    }
  }
}
