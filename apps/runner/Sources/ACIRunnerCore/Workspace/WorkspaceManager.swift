import Foundation

/// Creates isolated job directories and resolves contained paths.
///
/// The protocol allows ``JobExecutor`` tests to replace filesystem behavior
/// without weakening the production implementation's containment checks.
public protocol WorkspaceManaging: Sendable {
  /// Creates a unique workspace for a job attempt.
  func createWorkspace(for jobID: UUID) throws -> Workspace
  /// Resolves a relative path and verifies that it remains within the workspace.
  func resolve(_ relativePath: String, in workspace: Workspace) throws -> URL
  /// Removes a workspace only when it is still beneath the configured base.
  func removeWorkspace(_ workspace: Workspace) throws
}

/// The filesystem-backed implementation of ``WorkspaceManaging``.
public struct WorkspaceManager: WorkspaceManaging, Sendable {
  /// The directory under which all job and attempt directories are created.
  public let baseDirectory: URL

  /// Creates a workspace manager without creating the base directory yet.
  /// - Parameter baseDirectory: An absolute local file URL.
  public init(baseDirectory: URL) throws {
    guard baseDirectory.isFileURL,
          NSString(string: baseDirectory.path).isAbsolutePath
    else {
      throw WorkspaceError.unsafeBaseDirectory(baseDirectory)
    }

    self.baseDirectory = baseDirectory.standardizedFileURL
  }

  /// Creates `<base>/<job-id>/<attempt-id>` and returns the attempt directory.
  public func createWorkspace(for jobID: UUID) throws -> Workspace {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: baseDirectory,
      withIntermediateDirectories: true
    )

    let canonicalBase = baseDirectory.resolvingSymlinksInPath().standardizedFileURL
    let directory = canonicalBase
      .appendingPathComponent(jobID.uuidString.lowercased(), isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
      .standardizedFileURL

    guard contains(directory, inside: canonicalBase) else {
      throw WorkspaceError.pathEscapesWorkspace(directory.path)
    }

    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    return Workspace(rootURL: directory)
  }

  /// Resolves a workspace-relative path with lexical and symbolic-link checks.
  ///
  /// Paths may refer to outputs that do not exist yet. To handle a symbolic
  /// link followed by nonexistent components safely, resolution canonicalizes
  /// the deepest existing ancestor before rebuilding the remaining suffix.
  public func resolve(_ relativePath: String, in workspace: Workspace) throws -> URL {
    guard isSafeRelativePath(relativePath) else {
      throw WorkspaceError.unsafePath(relativePath)
    }

    let root = workspace.rootURL.resolvingSymlinksInPath().standardizedFileURL
    let unresolvedCandidate = root
      .appendingPathComponent(relativePath)
      .standardizedFileURL
    let candidate = resolvingExistingAncestors(of: unresolvedCandidate)

    guard contains(candidate, inside: root) else {
      throw WorkspaceError.pathEscapesWorkspace(relativePath)
    }

    return candidate
  }

  /// Removes an attempt directory and its empty job directory.
  ///
  /// Canonical containment is checked again immediately before deletion. If
  /// repository code replaced the workspace with an external symbolic link,
  /// cleanup fails closed instead of deleting the external target.
  public func removeWorkspace(_ workspace: Workspace) throws {
    let canonicalBase = baseDirectory.resolvingSymlinksInPath().standardizedFileURL
    let canonicalWorkspace = workspace.rootURL.resolvingSymlinksInPath().standardizedFileURL

    guard canonicalWorkspace != canonicalBase,
          contains(canonicalWorkspace, inside: canonicalBase)
    else {
      throw WorkspaceError.workspaceOutsideBase(workspace.rootURL)
    }

    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: canonicalWorkspace.path) {
      try fileManager.removeItem(at: canonicalWorkspace)
    }

    let jobDirectory = canonicalWorkspace.deletingLastPathComponent()
    if jobDirectory != canonicalBase,
       let remainingItems = try? fileManager.contentsOfDirectory(atPath: jobDirectory.path),
       remainingItems.isEmpty {
      try? fileManager.removeItem(at: jobDirectory)
    }
  }

  private func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty,
          !NSString(string: path).isAbsolutePath,
          !path.unicodeScalars.contains(where: { $0.value == 0 }),
          path != "~",
          !path.hasPrefix("~/")
    else {
      return false
    }

    return !NSString(string: path).pathComponents.contains("..")
  }

  private func contains(_ candidate: URL, inside root: URL) -> Bool {
    let rootComponents = root.standardizedFileURL.pathComponents
    let candidateComponents = candidate.standardizedFileURL.pathComponents

    guard candidateComponents.count >= rootComponents.count else {
      return false
    }

    return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
  }

  /// Resolves symlinks even when the final path components do not exist yet.
  private func resolvingExistingAncestors(of url: URL) -> URL {
    let fileManager = FileManager.default
    var existingAncestor = url.standardizedFileURL
    var missingComponents: [String] = []

    while !fileManager.fileExists(atPath: existingAncestor.path),
          existingAncestor.pathComponents.count > 1 {
      missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
      existingAncestor.deleteLastPathComponent()
    }

    var resolved = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
    for component in missingComponents {
      resolved.appendPathComponent(component)
    }
    return resolved.standardizedFileURL
  }
}
