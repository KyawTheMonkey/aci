import Foundation

/// Identifies the immutable source revision prepared before job steps run.
///
/// The clone URL must not contain credentials. A future control-plane lease
/// will deliver short-lived authentication separately from this durable job
/// specification.
public struct RepositorySpecification: Codable, Sendable, Equatable {
  /// The reserved identifier used for synthesized checkout logs and results.
  public static let checkoutStepID = "checkout"

  /// The credential-free URL used to fetch repository objects.
  ///
  /// Production jobs use HTTPS. Local acceptance tests may explicitly enable
  /// `file://` URLs at the runner CLI boundary.
  public let cloneURL: URL

  /// The complete lowercase SHA-1 commit identifier to check out.
  public let commitSHA: String

  /// Creates an immutable repository checkout request.
  public init(cloneURL: URL, commitSHA: String) {
    self.cloneURL = cloneURL
    self.commitSHA = commitSHA
  }
}
