import Foundation

/// Inspects the local Mac and produces scheduler-facing runner capabilities.
///
/// Toolchain probes are intentionally best-effort. A Mac without Xcode remains
/// a valid runner host; it simply advertises no Xcode or simulator capability.
public struct CapabilityDetector: Sendable {
  private let commandExecutor: any CommandExecuting

  /// Creates a detector using the supplied process backend.
  public init(commandExecutor: any CommandExecuting = CommandExecutor()) {
    self.commandExecutor = commandExecutor
  }

  /// Detects host, storage, Xcode, and simulator capabilities concurrently.
  public func detect() async -> RunnerCapabilities {
    async let xcodePath = capture(
      executable: "/usr/bin/xcode-select",
      arguments: ["--print-path"]
    )
    async let xcodeVersion = capture(
      executable: "/usr/bin/xcodebuild",
      arguments: ["-version"]
    )
    async let runtimesJSON = capture(
      executable: "/usr/bin/xcrun",
      arguments: ["simctl", "list", "runtimes", "--json"]
    )

    let runtimeOutput = await runtimesJSON

    return RunnerCapabilities(
      runnerVersion: ACIRunnerVersion.current,
      protocolVersion: ACIRunnerVersion.protocolVersion,
      operatingSystem: "macos",
      operatingSystemVersion: operatingSystemVersion,
      architecture: architecture,
      hostname: ProcessInfo.processInfo.hostName,
      xcodePath: await xcodePath?.trimmedNonempty,
      xcodeVersion: await xcodeVersion?.trimmedNonempty,
      simulatorRuntimes: decodeRuntimeNames(from: runtimeOutput),
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

  private var availableDiskBytes: Int64? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: home),
          let freeSize = attributes[.systemFreeSize] as? NSNumber
    else {
      return nil
    }

    return freeSize.int64Value
  }

  private func capture(executable: String, arguments: [String]) async -> String? {
    let collector = OutputCollector()
    let command = Command(
      executableURL: URL(fileURLWithPath: executable),
      arguments: arguments,
      environment: ProcessInfo.processInfo.environment,
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
