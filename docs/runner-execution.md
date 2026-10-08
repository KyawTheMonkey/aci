# ACI Runner Execution

## Purpose

This document describes the command-execution path that is implemented in the macOS runner. It covers local JSON jobs today and defines the execution behavior that the future control-plane service will reuse.

Remote job dispatch, authenticated checkout, network log upload, artifact upload, and runner registration are outside this implementation slice.

## Try it locally

From the runner package directory:

```bash
cd apps/runner
swift build
swift test
swift run aci-runner capabilities
swift run aci-runner execute --job Fixtures/Jobs/success.json
```

Other fixtures exercise expected user failures, timeout handling, and `continueOnError`:

```bash
swift run aci-runner execute --job Fixtures/Jobs/failure.json
swift run aci-runner execute --job Fixtures/Jobs/timeout.json
swift run aci-runner execute --job Fixtures/Jobs/continue-after-failure.json
```

The failure and timeout fixtures intentionally make the CLI return a nonzero status. Exit statuses distinguish outcomes so scripts and supervisors can react without parsing output:

| Exit status | Meaning |
| ---: | --- |
| `0` | Job succeeded |
| `1` | A step failed |
| `65` | The job file could not be read or failed validation |
| `70` | A runner infrastructure failure |
| `124` | The job or a step timed out |
| `130` | The job was cancelled by `SIGINT` or `SIGTERM` |

Pass `--result <path>` to also write the complete `JobResult` as JSON.

Pass `--workspace-root <path>` to place temporary job directories under a custom root. By default, they are created below `~/Library/Caches/ACI/Runner/workspaces.noindex`. The `.noindex` suffix keeps Spotlight from indexing derived data and simulator output, which measurably slows Xcode builds, and the caches location keeps build trees out of Time Machine backups.

The bundled fixtures are command-only diagnostic jobs and omit the optional `repository` property. Server-created CI jobs will include a credential-free clone URL and exact commit SHA.

For an end-to-end iOS workload, run:

```bash
./scripts/verify-runner-ios.sh --all
```

The script selects an available iPhone Simulator, creates a temporary Git repository from `samples/ios/ACISample`, commits it, generates normalized exact-SHA jobs, and invokes the release runner. Run it without `--all` when only the successful checkout and XCTest path is needed.

## Execution pipeline

```text
JSON job
   |
   v
decode JobSpecification
   |
   v
validate contract and paths
   |
   v
create isolated workspace
   |
   v
fetch and check out the exact commit, when requested
   |
   v
resolve each step into an exact Command
   |
   v
launch an isolated process session
   |\
   | +--> drain stdout --> incremental UTF-8 decode --+
   |                                                |
   +----> drain stderr --> incremental UTF-8 decode --+--> sequence LogEvent values
   |
   v
classify process and step result
   |
   v
continue, stop, or cancel remaining steps
   |
   v
remove workspace when configured
```

`JobExecutor` coordinates the job. It validates the complete specification before creating a workspace, calculates the overall job deadline, resolves step working directories inside the workspace, merges step variables over the allowlisted runner environment, and runs steps sequentially.

`CommandExecutor` handles one command. It receives only resolved runtime values: an absolute executable path, an argument array, a complete environment, and a working-directory URL.

## Repository preparation

A normalized job may include:

```json
{
  "repository": {
    "cloneURL": "https://github.com/example/ios-app.git",
    "commitSHA": "0123456789abcdef0123456789abcdef01234567"
  }
}
```

The validator requires a credential-free HTTPS URL with no query or fragment and a complete lowercase 40-character SHA-1 commit identifier. Branches, tags, abbreviated SHAs, URL-embedded tokens, and SCP-style SSH locations are rejected.

The CLI's `--allow-local-repository` flag additionally accepts absolute local `file://` URLs for the offline acceptance harness. The option is disabled by default and is not part of the server-to-runner production contract.

Repository preparation runs before user command steps:

1. Initialize an empty Git repository in the job workspace.
2. Fetch only the requested commit with no tags and depth one.
3. Check out that exact SHA in detached-HEAD mode.

The checkout does not depend on a mutable remote branch at execution time. Global and system Git configuration are disabled, and `GIT_TERMINAL_PROMPT=0` prevents a self-hosted runner from hanging on an interactive credential request. Each invocation also passes `-c protocol.version=2 -c gc.auto=0 -c core.fsmonitor=false -c fetch.recurseSubmodules=no -c advice.detachedHead=false` so no background maintenance, filesystem-monitor daemon, or implicit submodule traffic runs inside the workspace.

Fetch is the only network stage and the only one that is retried. A failed fetch is retried up to two times, after two and then five seconds, when Git's diagnostics do not indicate a permanent condition. Unknown commits (`not our ref`), missing repositories, and rejected credentials fail immediately. A retry is skipped when the remaining job time could not accommodate it, and each retry is announced on the checkout step's stderr.

Checkout shares the overall job deadline and uses the same process-group cancellation and log pipeline as user commands. Its logs and result use the reserved synthetic `checkout` step identifier, which user command steps cannot reuse when a repository is present. A Git exit failure is a job failure; inability to launch Git is an infrastructure failure.

Authentication is intentionally not part of this slice. The future runner protocol will provide a short-lived credential only after validating the runner, job attempt, and active lease. That credential must not be embedded in `cloneURL` or persisted in repository configuration.

Submodule initialization, Git LFS authentication, sparse checkout, and repository caching are not implemented yet.

## Exact command invocation

Commands do not pass through a shell implicitly. The executable and every argument are sent directly to the operating system. This avoids an extra quoting layer and makes the normalized job specification deterministic.

Shell behavior must be requested explicitly. For example:

```json
{
  "executable": "/bin/zsh",
  "arguments": ["-lc", "set -o pipefail; xcodebuild test -scheme Example"]
}
```

The runner does not search `PATH` for the executable in the current contract. Job producers must provide an absolute executable path beginning with `/`; `~`-prefixed paths are rejected.

## Step environment

Steps do not inherit the runner's complete environment. A future service process will hold runner credentials and lease tokens there, and repository code must never see them. `ProcessEnvironmentPolicy` copies only an allowlist of host variables (`PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `TERM`, `LANG`, `LC_*`, `COMMAND_MODE`, `DEVELOPER_DIR`, `__CF_USER_TEXT_ENCODING`, `XPC_FLAGS`, `XPC_SERVICE_NAME`). The runner then adds:

| Variable | Value |
| --- | --- |
| `CI`, `ACI` | `true` |
| `ACI_JOB_ID` | The lowercase job identifier |
| `ACI_WORKSPACE` | The absolute workspace root |
| `ACI_COMMIT_SHA` | The checked-out commit, when a repository is present |
| `ACI_TMPDIR`, `TMPDIR` | `<workspace>/.aci/tmp`, removed with the workspace |

Step-level `environment` values are merged last and override both sets. Git and capability probes use the same allowlist.

## Process isolation and teardown

Every command starts through Swift Subprocess with `createSession` enabled. On macOS, this places the command at the head of a new session and process group. Descendants normally inherit that group, allowing the runner to terminate a command tree without signalling itself.

The normal path is:

```text
launch --> stream output --> root process exits --> return result
```

Timeout and cancellation share one teardown path:

```text
deadline or task cancellation
          |
          v
cancel the Subprocess task
          |
          v
SIGTERM the process group
          |
          v
wait for the grace period
          |
          +--> all processes exit --> return result
          |
          v
SIGKILL the process group
```

The production default grace period is two seconds. Tests inject a shorter duration so escalation behavior can be verified quickly.

Because steps run in their own session, they never receive the terminal's `SIGINT` or launchd's `SIGTERM`; only the runner's teardown can stop them. The CLI therefore routes `SIGINT` and `SIGTERM` into cancellation of the job task, which terminates the process group, removes the workspace, prints the summary, and exits with status `130`. `SIGPIPE` is handled so a closed log consumer (`aci-runner execute … | head`) stops log output without killing the job. Signal handlers, rather than `SIG_IGN`, are installed so step processes start with default dispositions.

Process-group control is not a sandbox. A repository command still has the filesystem, network, keychain, and other permissions of the macOS account running `aci-runner`. Self-hosted operators must treat repository code as trusted for that machine until stronger isolation is introduced.

A descendant can also deliberately create a different session or process group and escape group-directed teardown. Hosted runners will ultimately require an ephemeral VM or equivalent isolation boundary.

## Timeout and cancellation semantics

A step's effective timeout is the smaller of:

- The step timeout, when present.
- The time remaining before the overall job deadline.

The runner distinguishes why execution stopped:

| Condition | Command outcome | Job behavior |
| --- | --- | --- |
| Exit status `0` | `succeeded` | Continue to the next step |
| Nonzero exit status | `failed` | Stop unless `continueOnError` is true |
| Effective deadline reached | `timedOut` | Stop the job |
| Parent Swift task cancelled | `cancelled` | Stop the job |
| Step executable or working directory does not exist | thrown `executableUnavailable` / `workingDirectoryUnavailable` | Record `failed`; honor `continueOnError` |
| Step working directory resolves outside the workspace | thrown `WorkspaceError` | Record `failed` |
| Any other launch or I/O error | thrown error | Record `infrastructureFailed` |

A workflow that names a tool or directory missing from this runner is a job mistake, not a runner fault. Classifying it as `failed` keeps a future scheduler from re-dispatching the same broken job across the pool. The same launch failure for a runner-owned tool, such as Git, remains an infrastructure failure.

The deadline timer and caller cancellation race against natural process exit. A single first-writer-wins state records which happened first, so a process that exited at the deadline is classified by its exit status rather than reported as timed out.

The exit code for signal termination is the signal number reported by Swift Subprocess, and `StepResult.terminationReason` records whether `exitCode` is an exit status or a signal. A step that honors `SIGTERM` reports `15`; one that ignores it and is force-killed reports `9`, and both carry `uncaughtSignal`. Without the reason, an exit status of `9` would be indistinguishable from `SIGKILL`.

## Output and log ordering

Stdout and stderr are drained in separate concurrent tasks. This is required because waiting on one full pipe while ignoring the other can deadlock a noisy build tool.

Each pipe is decoded incrementally. If a multi-byte UTF-8 scalar crosses two buffers, the incomplete suffix is retained until the next buffer arrives. Invalid or incomplete bytes at the end of the stream currently use Swift's replacement-character decoding because `LogEvent` carries text rather than arbitrary bytes.

An actor assigns monotonically increasing sequence numbers as decoded chunks arrive. This provides a stable event order for storage and display, but stdout and stderr are independent pipes: no API can recover their original byte-level interleaving after the child writes to both concurrently.

The future network log protocol will add batching, acknowledgements, retries, size limits, redaction, and an explicit representation for non-UTF-8 output.

## Workspace cleanup

`JobExecutor` removes the workspace after orchestration finishes when `cleanAfterExecution` is enabled. Cleanup therefore runs after success, command failure, timeout, cancellation, and infrastructure failure.

Build tools leave read-only directories behind. When removal fails, `WorkspaceManager` restores owner permissions on every directory beneath the workspace without following symbolic links and tries once more. A cleanup failure is never silent: it is logged through `os.Logger` and reported in `JobResult.warnings`, which the CLI prints, because an unnoticed cleanup failure eventually fills the disk.

Workspace cleanup is separate from process teardown. On timeout and cancellation, the process group is terminated before execution returns and before the workspace is removed.

On a successful root-process exit, the current executor does not terminate descendants that intentionally continue running in the background. Preventing successful steps from leaving background processes is a future runner-hardening task.

## Verification coverage

The command-executor tests cover:

- Successful and nonzero exits.
- Concurrent stdout and stderr streaming.
- Timeout and caller cancellation classification.
- Termination of parent and descendant processes.
- Escalation to `SIGKILL` when `SIGTERM` is ignored.
- A descendant retaining inherited pipe descriptors.
- UTF-8 scalars split across separate writes.
- Large simultaneous stdout and stderr streams.
- The real termination signal is reported after a timeout.
- A process exiting at the deadline is not misreported as timed out.
- Missing executables and working directories throw typed launch failures.

Job-executor behavior tests with real processes verify:

- A working directory that escapes the workspace mid-job fails that step and keeps earlier results.
- Missing user executables and directories are step failures; a missing runner tool is an infrastructure failure.
- Step results carry exit codes and termination reasons.
- Steps receive the allowlisted environment, the ACI variables, and a workspace-local `TMPDIR`.
- Cancelling the job terminates the running step and removes the workspace.
- The job deadline prevents later steps from starting.
- Workspaces are removed after every outcome.

Repository-preparation tests create real temporary Git repositories and verify:

- An older requested commit is checked out instead of the current branch tip.
- An unknown but well-formed commit SHA fails during fetch without retries.
- Transient fetch failures are retried and announced before checkout proceeds.
- Git is not launched after the overall job deadline.
- Checkout failures prevent later command steps from running.
- Clone URLs, commit SHAs, and the reserved checkout step ID are validated.

The iOS acceptance harness additionally verifies:

- Exact-SHA checkout followed by a successful iOS Simulator XCTest run.
- Swift compilation failures are reported as failed jobs.
- XCTest failures are reported as failed jobs.
- A long-running `xcodebuild` process tree is terminated at its step deadline.
- A valid but unknown commit SHA fails before user commands run.

Run the strict local verification suite with:

```bash
swift test --package-path apps/runner -Xswiftc -warnings-as-errors
swift build --package-path apps/runner -c release -Xswiftc -warnings-as-errors
./scripts/benchmark-runner.sh
```

The runner package currently targets macOS 13 or later and pins Swift Subprocess through `Package.resolved` for reproducible local builds.

Performance is a tested runner contract. The isolated `apps/runner/Performance` Swift package measures decoding, validation, orchestration, real process launch, and log draining. A separate process probe enforces ceilings for the release binary and peak resident memory. Benchmark dependencies stay out of the production runner package and are not linked into `aci-runner`. See [Runner performance](runner-performance.md) for current measurements and regression thresholds.

## Next implementation step

Milestone 1 is accepted through the Swift test suite, the repeatable iOS harness, and the runner performance guardrails. Development now moves to the durable Vapor control plane:

1. Define the first job, attempt, step, and runner state machines.
2. Add Fluent models and migrations for those aggregates.
3. Enforce legal transitions in a database-independent domain layer.
4. Create queued jobs transactionally.
5. Keep PostgreSQL authoritative for every transition.
