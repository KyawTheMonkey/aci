# ACI Runner Execution

## Purpose

This document describes the command-execution path that is implemented in the macOS runner. It covers local JSON jobs today and defines the execution behavior that the future control-plane service will reuse.

Repository checkout, remote job dispatch, network log upload, artifact upload, and runner registration are outside this implementation slice.

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

The failure and timeout fixtures intentionally make the CLI return a nonzero status.

Pass `--workspace-root <path>` to place temporary job directories under a custom root. By default, they are created below `~/Library/Application Support/ACI/Runner/workspaces`.

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

`JobExecutor` coordinates the job. It validates the complete specification before creating a workspace, calculates the overall job deadline, resolves step working directories inside the workspace, merges step variables over the runner environment, and runs steps sequentially.

`CommandExecutor` handles one command. It receives only resolved runtime values: an absolute executable path, an argument array, a complete environment, and a working-directory URL.

## Exact command invocation

Commands do not pass through a shell implicitly. The executable and every argument are sent directly to the operating system. This avoids an extra quoting layer and makes the normalized job specification deterministic.

Shell behavior must be requested explicitly. For example:

```json
{
  "executable": "/bin/zsh",
  "arguments": ["-lc", "set -o pipefail; xcodebuild test -scheme Example"]
}
```

The runner does not search `PATH` for the executable in the current contract. Job producers must provide an absolute executable path.

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
| Executor infrastructure error | thrown error | Record `infrastructureFailed` |

The exit code for signal termination is the signal number reported by Swift Subprocess. For example, forced termination by `SIGKILL` is represented by `9` together with an `uncaughtSignal` termination reason.

## Output and log ordering

Stdout and stderr are drained in separate concurrent tasks. This is required because waiting on one full pipe while ignoring the other can deadlock a noisy build tool.

Each pipe is decoded incrementally. If a multi-byte UTF-8 scalar crosses two buffers, the incomplete suffix is retained until the next buffer arrives. Invalid or incomplete bytes at the end of the stream currently use Swift's replacement-character decoding because `LogEvent` carries text rather than arbitrary bytes.

An actor assigns monotonically increasing sequence numbers as decoded chunks arrive. This provides a stable event order for storage and display, but stdout and stderr are independent pipes: no API can recover their original byte-level interleaving after the child writes to both concurrently.

The future network log protocol will add batching, acknowledgements, retries, size limits, redaction, and an explicit representation for non-UTF-8 output.

## Workspace cleanup

`JobExecutor` removes the workspace in a `defer` block when `cleanAfterExecution` is enabled. Cleanup therefore runs after success, command failure, timeout, cancellation, and infrastructure failure.

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

Run the strict local verification suite with:

```bash
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
```

The runner package currently targets macOS 13 or later and pins Swift Subprocess through `Package.resolved` for reproducible local builds.

## Next implementation step

The remaining Milestone 1 task is repository preparation:

1. Validate a repository checkout request.
2. Obtain source into the isolated workspace.
3. Check out the exact immutable commit SHA.
4. Remove any temporary credential material.
5. Hand the prepared workspace to the existing job-execution pipeline.

The checkout implementation must not weaken the existing rule that step working directories remain inside the job workspace.
