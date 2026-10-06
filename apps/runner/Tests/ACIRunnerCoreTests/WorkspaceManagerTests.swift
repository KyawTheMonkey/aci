import ACIRunnerCore
import Foundation
import Testing

@Suite("Workspace manager")
struct WorkspaceManagerTests {
  @Test("Creates unique workspaces and removes them")
  func createAndRemove() throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let manager = try WorkspaceManager(baseDirectory: base)
    let jobID = UUID()

    let first = try manager.createWorkspace(for: jobID)
    let second = try manager.createWorkspace(for: jobID)

    #expect(first.rootURL != second.rootURL)
    #expect(FileManager.default.fileExists(atPath: first.rootURL.path))
    #expect(FileManager.default.fileExists(atPath: second.rootURL.path))

    try manager.removeWorkspace(first)
    try manager.removeWorkspace(second)

    #expect(!FileManager.default.fileExists(atPath: first.rootURL.path))
    #expect(!FileManager.default.fileExists(atPath: second.rootURL.path))
  }

  @Test("Creates a missing base beneath a symlinked ancestor")
  func createsMissingBaseBeneathSymlink() throws {
    let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("aci-runner-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let manager = try WorkspaceManager(baseDirectory: base)

    let workspace = try manager.createWorkspace(for: UUID())

    #expect(FileManager.default.fileExists(atPath: workspace.rootURL.path))
    try manager.removeWorkspace(workspace)
  }

  @Test("Rejects lexical parent traversal")
  func rejectsParentTraversal() throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let manager = try WorkspaceManager(baseDirectory: base)
    let workspace = try manager.createWorkspace(for: UUID())

    #expect(throws: WorkspaceError.self) {
      _ = try manager.resolve("../outside", in: workspace)
    }
  }

  @Test("Rejects a symbolic link that resolves outside the workspace")
  func rejectsSymlinkEscape() throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let outside = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: outside) }
    let manager = try WorkspaceManager(baseDirectory: base)
    let workspace = try manager.createWorkspace(for: UUID())
    let link = workspace.rootURL.appendingPathComponent("outside")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    #expect(throws: WorkspaceError.self) {
      _ = try manager.resolve("outside/secret.txt", in: workspace)
    }
  }
}
