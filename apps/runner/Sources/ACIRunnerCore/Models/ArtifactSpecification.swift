/// Describes a build output that ACI should collect from a job workspace.
///
/// Artifact paths are always relative to the workspace. The specification
/// validator rejects absolute paths and parent-directory traversal before a
/// job starts, and the workspace manager performs a second containment check
/// when the path is resolved.
public struct ArtifactSpecification: Codable, Sendable, Equatable {
  /// The workspace-relative path to a file or directory.
  public let path: String

  /// Whether the job should fail when no artifact exists at ``path``.
  public let required: Bool

  /// Creates an artifact declaration.
  /// - Parameters:
  ///   - path: A path relative to the job workspace.
  ///   - required: Whether the artifact must exist after execution.
  public init(path: String, required: Bool) {
    self.path = path
    self.required = required
  }
}
