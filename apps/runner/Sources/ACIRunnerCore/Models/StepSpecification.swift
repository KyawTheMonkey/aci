import Foundation

public enum StepKind: String, Codable, Sendable {
  case command
}

public struct StepSpecification: Codable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let kind: StepKind
  public let executable: String
  public let arguments: [String]
  public let environment: [String: String]
  public let workingDirectory: String?
  public let timeoutSeconds: Int?
  public let continueOnError: Bool
}
