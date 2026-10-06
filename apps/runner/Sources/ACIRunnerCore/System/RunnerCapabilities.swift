import Foundation

/// Version information advertised by this runner build.
public enum ACIRunnerVersion {
  /// The runner application's semantic version.
  public static let current = "0.1.0"
  /// The control-plane protocol version implemented by the runner.
  public static let protocolVersion = 1
}

/// The scheduling capabilities detected on a runner host.
public struct RunnerCapabilities: Codable, Sendable, Equatable {
  /// The installed ACI runner version.
  public let runnerVersion: String
  /// The runner-control-plane protocol version.
  public let protocolVersion: Int
  /// The normalized operating-system family.
  public let operatingSystem: String
  /// The host operating-system version.
  public let operatingSystemVersion: String
  /// The host CPU architecture.
  public let architecture: String
  /// The host name reported by the operating system.
  public let hostname: String
  /// The active developer directory, when Xcode is available.
  public let xcodePath: String?
  /// The active Xcode version and build, when available.
  public let xcodeVersion: String?
  /// Available Apple simulator runtime names.
  public let simulatorRuntimes: [String]
  /// Free bytes on the filesystem containing the user's home directory.
  public let availableDiskBytes: Int64?
  /// The number of jobs this runner currently permits at once.
  public let maximumConcurrency: Int
  /// Scheduler labels automatically assigned to the runner.
  public let labels: [String]

  /// Creates a complete capability report.
  public init(
    runnerVersion: String,
    protocolVersion: Int,
    operatingSystem: String,
    operatingSystemVersion: String,
    architecture: String,
    hostname: String,
    xcodePath: String?,
    xcodeVersion: String?,
    simulatorRuntimes: [String],
    availableDiskBytes: Int64?,
    maximumConcurrency: Int,
    labels: [String]
  ) {
    self.runnerVersion = runnerVersion
    self.protocolVersion = protocolVersion
    self.operatingSystem = operatingSystem
    self.operatingSystemVersion = operatingSystemVersion
    self.architecture = architecture
    self.hostname = hostname
    self.xcodePath = xcodePath
    self.xcodeVersion = xcodeVersion
    self.simulatorRuntimes = simulatorRuntimes
    self.availableDiskBytes = availableDiskBytes
    self.maximumConcurrency = maximumConcurrency
    self.labels = labels
  }
}
