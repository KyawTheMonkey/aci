import ACIRunnerCore
import Darwin
import Foundation
import Testing

/// Orchestration behavior that needs real processes or a real workspace.
@Suite("Job executor behavior", .serialized)
struct JobExecutorBehaviorTests {
  @Test("A working directory that escapes mid-job fails the step and keeps earlier results")
  func workingDirectoryEscapeIsAStepFailure() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let outside = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: outside) }
    let executor = JobExecutor(workspaceManager: try WorkspaceManager(baseDirectory: base))
    let job = makeJob(steps: [
      makeStep(id: "link", executable: "/bin/ln", arguments: ["-s", outside.path, "out"]),
      makeStep(id: "use", executable: "/bin/pwd", workingDirectory: "out"),
    ])

    let result = try await executor.execute(job)

    #expect(result.outcome == .failed)
    #expect(result.stepResults.map(\.stepID) == ["link", "use"])
    #expect(result.stepResults.map(\.outcome) == [.succeeded, .failed])
    #expect(result.stepResults.last?.failureReason?.contains("escapes") == true)
  }

  @Test("A missing executable or working directory is a step failure, not a runner fault")
  func missingUserPathsAreStepFailures() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let executor = JobExecutor(workspaceManager: try WorkspaceManager(baseDirectory: base))
    let job = makeJob(steps: [
      makeStep(id: "missing-executable", executable: "/opt/aci/not-installed", continueOnError: true),
      makeStep(id: "missing-directory", workingDirectory: "does-not-exist"),
      makeStep(id: "never-runs"),
    ])

    let result = try await executor.execute(job)

    #expect(result.outcome == .failed)
    #expect(result.stepResults.map(\.stepID) == ["missing-executable", "missing-directory"])
    #expect(result.stepResults.map(\.outcome) == [.failed, .failed])
    #expect(result.stepResults.allSatisfy { $0.exitCode == nil })
  }

  @Test("Launch failures of runner-owned tools remain infrastructure failures")
  func runnerToolLaunchFailureIsInfrastructure() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let executor = JobExecutor(
      workspaceManager: try WorkspaceManager(baseDirectory: base),
      repositoryPreparer: GitRepositoryPreparer(
        gitExecutableURL: URL(fileURLWithPath: "/opt/aci/missing-git")
      )
    )

    let result = try await executor.execute(makeJob(repository: makeRepository()))

    #expect(result.outcome == .infrastructureFailed)
    #expect(result.stepResults.first?.stepID == "checkout")
  }

  @Test("Step results carry the termination reason")
  func terminationReasonIsRecorded() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let executor = JobExecutor(workspaceManager: try WorkspaceManager(baseDirectory: base))
    let job = makeJob(steps: [
      makeStep(id: "exit", executable: "/bin/sh", arguments: ["-c", "exit 9"], continueOnError: true),
      makeStep(id: "signal", executable: "/bin/sh", arguments: ["-c", "kill -KILL $$"]),
    ])

    let result = try await executor.execute(job)

    #expect(result.stepResults.map(\.exitCode) == [9, SIGKILL])
    #expect(result.stepResults.map(\.terminationReason) == [.exit, .uncaughtSignal])
    #expect(result.failureReason == "Step 'signal' was terminated by signal 9.")
  }

  @Test("Steps receive an allowlisted environment with ACI job variables")
  func stepEnvironmentIsAllowlisted() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    setenv("ACI_TEST_RUNNER_SECRET", "must-not-leak", 1)
    defer { unsetenv("ACI_TEST_RUNNER_SECRET") }
    let executor = JobExecutor(workspaceManager: try WorkspaceManager(baseDirectory: base))
    let collector = TextCollector()
    let job = makeJob(
      repository: nil,
      steps: [
        makeStep(
          id: "env",
          executable: "/usr/bin/env",
          environment: ["ACI_STEP_VARIABLE": "step"]
        )
      ]
    )

    let result = try await executor.execute(job) { event in
      await collector.append(event.text)
    }
    let variables = Dictionary(
      uniqueKeysWithValues: await collector.text
        .split(separator: "\n")
        .compactMap { line -> (String, String)? in
          guard let separator = line.firstIndex(of: "=") else { return nil }
          return (String(line[..<separator]), String(line[line.index(after: separator)...]))
        }
    )

    #expect(result.outcome == .succeeded)
    #expect(variables["ACI_TEST_RUNNER_SECRET"] == nil)
    #expect(variables[JobEnvironment.ci] == "true")
    #expect(variables[JobEnvironment.jobID] == job.jobID.uuidString.lowercased())
    #expect(variables["ACI_STEP_VARIABLE"] == "step")
    #expect(variables["PATH"] == ProcessInfo.processInfo.environment["PATH"])
    let workspace = try #require(variables[JobEnvironment.workspace])
    #expect(variables["TMPDIR"]?.hasPrefix(workspace) == true)
    #expect(variables["TMPDIR"] == variables[JobEnvironment.temporaryDirectory])
  }

  @Test("Cancelling the job terminates the running step and removes the workspace")
  func cancellationPropagates() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let executor = JobExecutor(
      workspaceManager: try WorkspaceManager(baseDirectory: base),
      commandExecutor: CommandExecutor(terminationGracePeriod: .milliseconds(100))
    )
    let job = makeJob(steps: [
      makeStep(id: "sleep", executable: "/bin/sleep", arguments: ["30"], timeoutSeconds: 60),
      makeStep(id: "never-runs"),
    ])
    let execution = Task { try await executor.execute(job) }

    try await Task.sleep(for: .milliseconds(300))
    execution.cancel()
    let result = try await execution.value

    #expect(result.outcome == .cancelled)
    #expect(result.stepResults.map(\.stepID) == ["sleep"])
    #expect(result.stepResults.first?.outcome == .cancelled)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: base.path)
    #expect(remaining.isEmpty)
  }

  @Test("The job deadline stops later steps from starting")
  func jobDeadlineStopsLaterSteps() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let commandExecutor = ScriptedCommandExecutor(responses: [
      .result(makeCommandResult(outcome: .succeeded, exitCode: 0), delay: .milliseconds(1_200)),
      .result(makeCommandResult(outcome: .succeeded, exitCode: 0)),
    ])
    let executor = JobExecutor(
      workspaceManager: try WorkspaceManager(baseDirectory: base),
      commandExecutor: commandExecutor
    )
    let job = makeJob(
      timeoutSeconds: 1,
      steps: [makeStep(id: "slow", timeoutSeconds: 1), makeStep(id: "late", timeoutSeconds: 1)]
    )

    let result = try await executor.execute(job)

    #expect(result.outcome == .timedOut)
    #expect(result.stepResults.map(\.stepID) == ["slow"])
    #expect(result.failureReason == "Job timeout was reached before step 'late' started.")
    #expect(await commandExecutor.stepIDs == ["slow"])
  }

  @Test("Workspaces are removed after every outcome and results carry no warnings")
  func cleanupRunsForEveryOutcome() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let executor = JobExecutor(
      workspaceManager: try WorkspaceManager(baseDirectory: base),
      commandExecutor: CommandExecutor(terminationGracePeriod: .milliseconds(100))
    )
    let jobs = [
      makeJob(steps: [makeStep(id: "ok")]),
      makeJob(steps: [makeStep(id: "fail", executable: "/usr/bin/false")]),
      makeJob(steps: [makeStep(id: "slow", executable: "/bin/sleep", arguments: ["5"], timeoutSeconds: 1)]),
      makeJob(steps: [makeStep(id: "missing", executable: "/opt/aci/not-installed")]),
    ]

    var outcomes: [ExecutionOutcome] = []
    for job in jobs {
      let result = try await executor.execute(job)
      outcomes.append(result.outcome)
      #expect(result.warnings.isEmpty)
    }

    #expect(outcomes == [.succeeded, .failed, .timedOut, .failed])
    let remaining = try FileManager.default.contentsOfDirectory(atPath: base.path)
    #expect(remaining.isEmpty)
  }
}

private actor TextCollector {
  private(set) var text = ""

  func append(_ chunk: String) {
    text.append(chunk)
  }
}
