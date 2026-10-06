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

The failure and timeout fixtures intentionally make the CLI return a nonzero status.

Pass `--workspace-root <path>` to place temporary job directories under a custom root. By default, they are created below `~/Library/Application Support/ACI/Runner/workspaces`.

The bundled fixtures are command-only diagnostic jobs and omit the optional `repository` property. Server-created CI jobs will include a credential-free clone URL and exact commit SHA.

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

`JobExecutor` coordinates the job. It validates the complete specification before creating a workspace, calculates the overall job deadline, resolves step working directories inside the workspace, merges step variables over the runner environment, and runs steps sequentially.

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

Repository preparation runs before user command steps:

1. Initialize an empty Git repository in the job workspace.
2. Fetch only the requested commit with no tags and depth one.
3. Check out that exact SHA in detached-HEAD mode.

The checkout does not depend on a mutable remote branch at execution time. Global and system Git configuration are disabled, and `GIT_TERMINAL_PROMPT=0` prevents a self-hosted runner from hanging on an interactive credential request.

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

Repository-preparation tests create real temporary Git repositories and verify:

- An older requested commit is checked out instead of the current branch tip.
- An unknown but well-formed commit SHA fails during fetch.
- Git is not launched after the overall job deadline.
- Checkout failures prevent later command steps from running.
- Clone URLs, commit SHAs, and the reserved checkout step ID are validated.

Run the strict local verification suite with:

```bash
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
```

The runner package currently targets macOS 13 or later and pins Swift Subprocess through `Package.resolved` for reproducible local builds.

## Next implementation step

The Milestone 1 implementation checklist is complete. Its acceptance criterion still needs an end-to-end sample iOS project:

1. Add a minimal committed Xcode project and test target.
2. Create a normalized job that checks out its exact commit.
3. Run `xcodebuild test` through `aci-runner execute`.
4. Exercise compilation failure, test failure, timeout, cancellation, and an invalid commit SHA.
5. Record the repeatable verification command in this guide.

After that acceptance slice, development moves to the durable Vapor control plane: Fluent models, migrations, state transitions, and transactional job creation.
