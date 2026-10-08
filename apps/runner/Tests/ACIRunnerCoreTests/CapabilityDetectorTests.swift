import ACIRunnerCore
import Foundation
import Testing

@Suite("Capability detector")
struct CapabilityDetectorTests {
  @Test("Skips Xcode shims when no developer directory is selected")
  func skipsXcodeProbesWithoutDeveloperDirectory() async {
    let commandExecutor = ScriptedCommandExecutor(responses: [
      .result(makeCommandResult(outcome: .failed, exitCode: 2), stderr: "xcode-select: error: unable to get active developer directory\n")
    ])
    let detector = CapabilityDetector(commandExecutor: commandExecutor)

    let capabilities = await detector.detect()

    #expect(capabilities.xcodePath == nil)
    #expect(capabilities.xcodeVersion == nil)
    #expect(capabilities.simulatorRuntimes.isEmpty)
    #expect(await commandExecutor.commands.map(\.executableURL.path) == ["/usr/bin/xcode-select"])
  }

  @Test("Reports host facts without blocking on probes")
  func reportsHostFacts() async {
    let commandExecutor = ScriptedCommandExecutor(responses: [
      .result(makeCommandResult(outcome: .failed, exitCode: 2))
    ])
    let storage = FileManager.default.temporaryDirectory
      .appendingPathComponent("aci-not-created-yet", isDirectory: true)
    let detector = CapabilityDetector(commandExecutor: commandExecutor, storageURL: storage)

    let capabilities = await detector.detect()

    #expect(!capabilities.hostname.isEmpty)
    #expect(capabilities.operatingSystem == "macos")
    #expect(capabilities.labels.contains("self-hosted"))
    #expect((capabilities.availableDiskBytes ?? 0) > 0)
    #expect(await commandExecutor.commands.allSatisfy { $0.environment["PATH"] != nil })
  }
}
