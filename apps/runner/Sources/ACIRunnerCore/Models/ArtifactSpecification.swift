import Foundation

// TODO:
public struct ArtifactSpecification: Codable, Sendable, Equatable {
  public let path: String
  public let required: Bool
}
