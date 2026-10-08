import Darwin
import Foundation

/// Inspects the local Mac and produces scheduler-facing runner capabilities.
///
/// Toolchain probes are intentionally best-effort. A Mac without Xcode remains
/// a valid runner host; it simply advertises no Xcode or simulator capability.
public struct CapabilityDetector: Sendable {
  private let commandExecutor: any CommandExecuting
  private let environmentPolicy: ProcessEnvironmentPolicy
  private let storageURL: URL

  /// Creates a detector using the supplied process backend.
  /// - Parameters:
  ///   - commandExecutor: The backend used for toolchain probes.
  ///   - environmentPolicy: The environment handed to probe processes.
  ///   - storageURL: A location on the volume where job workspaces live. The
  ///     path does not need to exist yet; the nearest existing ancestor is
  ///     measured.
  public init(
    commandExecutor: any CommandExecuting = CommandExecutor(),
    environmentPolicy: ProcessEnvironmentPolicy = .init(),
    storageURL: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.commandExecutor = commandExecutor
    self.environmentPolicy = environmentPolicy
    self.storageURL = storageURL
  }

  /// Detects host, storage, Xcode, and simulator capabilities.
  ///
  /// `xcodebuild` and `xcrun` are shims that open a graphical "install the
  /// command line tools" prompt on a Mac without a developer directory, so they
  /// are only invoked after `xcode-select` confirms one exists.
  public func detect() async -> RunnerCapabilities {
    let xcodePath = await capture(
      executable: "/usr/bin/xcode-select",
      arguments: ["--print-path"]
    )?.trimmedNonempty

    var xcodeVersion: String?
    var simulatorRuntimes: [String] = []
    if xcodePath != nil {
      async let version = capture(
        executable: "/usr/bin/xcodebuild",
        arguments: ["-version"]
      )
      async let runtimesJSON = capture(
        executable: "/usr/bin/xcrun",
        arguments: ["simctl", "list", "runtimes", "--json"]
      )
      xcodeVersion = await version?.trimmedNonempty
      simulatorRuntimes = decodeRuntimeNames(from: await runtimesJSON)
    }

    return RunnerCapabilities(
      runnerVersion: ACIRunnerVersion.current,
      protocolVersion: ACIRunnerVersion.protocolVersion,
      operatingSystem: "macos",
      operatingSystemVersion: operatingSystemVersion,
      architecture: architecture,
      hostname: hostname,
      xcodePath: xcodePath,
      xcodeVersion: xcodeVersion,
      simulatorRuntimes: simulatorRuntimes,
      availableDiskBytes: availableDiskBytes,
      maximumConcurrency: 1,
      labels: ["self-hosted", "macos", architecture]
    )
  }

  private var operatingSystemVersion: String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
  }

  private var architecture: String {
    #if arch(arm64)
    "arm64"
    #elseif arch(x86_64)
    "x86_64"
    #else
    "unknown"
    #endif
  }

  /// The kernel host name.
  ///
  /// `ProcessInfo.hostName` performs a reverse DNS lookup that can stall for
  /// seconds on a misconfigured network; `gethostname` does not.
  private var hostname: String {
    var buffer = [UInt8](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
    let status = buffer.withUnsafeMutableBufferPointer { pointer in
      pointer.withMemoryRebound(to: CChar.self) { characters in
        gethostname(characters.baseAddress, characters.count - 1)
      }
    }
    guard status == 0 else {
      return "localhost"
    }
    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
  }

  /// Space a job may actually use on the workspace volume.
  ///
  /// APFS reports purgeable space as used, so `systemFreeSize` undercounts;
  /// the "important usage" capacity is the figure Finder shows and the one a
  /// scheduler should trust.
  private var availableDiskBytes: Int64? {
    var location = storageURL.standardizedFileURL
    while !FileManager.default.fileExists(atPath: location.path),
          location.pathComponents.count > 1 {
      location.deleteLastPathComponent()
    }

    let keys: Set<URLResourceKey> = [
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeAvailableCapacityKey,
    ]
    guard let values = try? location.resourceValues(forKeys: keys) else {
      return nil
    }

    return values.volumeAvailableCapacityForImportantUsage
      ?? values.volumeAvailableCapacity.map(Int64.init)
  }

  private func capture(executable: String, arguments: [String]) async -> String? {
    let collector = OutputCollector()
    let command = Command(
      executableURL: URL(fileURLWithPath: executable),
      arguments: arguments,
      environment: environmentPolicy.environment(),
      workingDirectoryURL: FileManager.default.temporaryDirectory
    )

    do {
      let result = try await commandExecutor.execute(
        command,
        stepID: "capability-probe",
        timeoutSeconds: 15
      ) { event in
        if event.stream == .stdout {
          await collector.append(event.text)
        }
      }

      guard result.outcome == .succeeded else { return nil }
      return await collector.value
    } catch {
      return nil
    }
  }

  private func decodeRuntimeNames(from json: String?) -> [String] {
    guard let json,
          let data = json.data(using: .utf8),
          let response = try? JSONDecoder().decode(SimulatorRuntimeResponse.self, from: data)
    else {
      return []
    }

    return Array(Set(response.runtimes
      .filter { $0.isAvailable != false }
      .map(\.name)))
      .sorted()
  }
}

private actor OutputCollector {
  private(set) var value = ""

  func append(_ text: String) {
    value.append(text)
  }
}

private struct SimulatorRuntimeResponse: Decodable {
  let runtimes: [SimulatorRuntime]
}

private struct SimulatorRuntime: Decodable {
  let name: String
  let isAvailable: Bool?
}

private extension String {
  var trimmedNonempty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
