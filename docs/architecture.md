# ACI Architecture

## Overview

ACI is an iOS-first CI/CD platform with a Swift control plane, a Next.js dashboard, and a Swift runner. It initially dispatches work to user-managed Macs and may later provide ACI-managed ephemeral macOS environments.

The primary architectural boundary separates trusted orchestration from untrusted build execution:

- The **control plane** accepts user and Git-provider events, validates workflows, schedules jobs, records state, and issues scoped credentials.
- The **runner plane** checks out and executes repository code on registered machines.

The control plane must never execute repository commands.

## Design principles

1. PostgreSQL is authoritative for workflow and job state.
2. Repository code is untrusted, regardless of repository visibility.
3. All checkouts use immutable commit SHAs.
4. Runners initiate network connections to the control plane.
5. Jobs are assigned through expiring leases.
6. Commands, logs, artifacts, and completion messages are idempotent where possible.
7. The scheduler uses platform-neutral capabilities rather than Xcode-specific columns.
8. The MVP favors straightforward HTTPS polling before persistent streaming protocols.

## System context

```text
                          +-------------------+
                          |      GitHub       |
                          | App, API, webhooks|
                          +---------+---------+
                                    |
                                    v
+-------------+           +---------+----------+
| Next.js web |---------->| Swift/Vapor server |
| dashboard   |           | API and scheduler  |
+-------------+           +----+-----------+----+
                               |           |
                    +----------+           +-----------+
                    v                                  v
              +-----+------+                    +------+------+
              | PostgreSQL |                    |    Redis    |
              | source of  |                    | transient   |
              | truth      |                    | coordination|
              +------------+                    +-------------+
                               |
                               | outbound HTTPS
                               v
                       +-------+--------+
                       | Swift runner   |
                       | on macOS       |
                       +-------+--------+
                               |
                               +------> git, xcodebuild, simctl
                               |
                               +------> S3-compatible artifacts
```

## Components

### Swift/Vapor server

Responsibilities:

- User and organization authorization
- GitHub App installation management
- Webhook authentication and ingestion
- Repository and workflow configuration
- Workflow compilation
- Workflow-run and job creation
- Runner registration and authentication
- Capability-based scheduling
- Lease creation and renewal
- Cancellation coordination
- Log ingestion and delivery
- Artifact metadata and pre-signed URL issuance
- GitHub check-run synchronization
- Audit events

The server may run multiple stateless instances. Transactions and database constraints must preserve correctness when instances process the same work concurrently.

### Scheduler

The scheduler is a server module or separate Swift process sharing the same domain layer.

It matches:

```text
Job requirements
    os, architecture, toolchains, labels, pool

against

Runner capabilities
    os, architecture, installed tools, labels, availability
```

Initial scheduling policy:

1. Restrict candidates to the authorized runner pool.
2. Require every job capability to be satisfied.
3. Select the oldest eligible queued job.
4. Assign it transactionally using `FOR UPDATE SKIP LOCKED`.
5. Create a random lease ID and expiration time.

Fairness, organization quotas, and cost-aware placement are post-MVP concerns.

### Swift runner

The runner is a separate macOS executable. It:

- Registers using a single-use token.
- Stores its credential in macOS Keychain.
- Reports machine capabilities and health.
- Polls for compatible work.
- Validates the received protocol and job-specification versions.
- Creates and cleans isolated workspaces.
- Checks out an exact commit SHA.
- Runs commands and controls their process trees.
- Uploads ordered logs, test results, and artifacts.
- Honors timeout and cancellation.
- Reports a terminal result once.

The same runner binary supports a developer's local Mac and a dedicated self-hosted Mac. Hosted runners will use an ephemeral registration mode.

#### Local command execution

`JobExecutor` owns job orchestration: validation, workspace lifecycle, overall deadlines, sequential steps, and result classification. `CommandExecutor` owns one operating-system process invocation.

Each command is launched with Swift Subprocess in a new session. The session creates a process group that can be signalled independently from the runner. On timeout or task cancellation, the runner sends `SIGTERM` to that group, waits for the configured grace period, and then escalates to `SIGKILL` when necessary.

Stdout and stderr are consumed concurrently so either pipe can produce high-volume output without blocking the child. UTF-8 is decoded incrementally before chunks become sequenced `LogEvent` values. The sequence records the order in which the runner observes chunks; it cannot reconstruct a total byte-level ordering between two independent operating-system pipes.

This process boundary improves lifecycle control but is not a sandbox. Repository commands still run with the runner account's host permissions. The detailed implementation contract and local verification commands are documented in [Runner execution](runner-execution.md).

### Next.js web application

The web application provides:

- GitHub sign-in and installation setup
- Repository enablement
- Workflow-run history
- Run, job, and step inspection
- Incremental logs
- Cancellation and rerun actions
- Runner-pool management
- One-time runner registration tokens
- Secret and artifact management

The web application uses the public control-plane API. It must not receive runner credentials or GitHub App private keys.

### PostgreSQL

PostgreSQL stores:

- Users, organizations, and memberships
- GitHub installations and repositories
- Runner pools, runners, and registration-token hashes
- Workflow runs, jobs, attempts, and steps
- Job leases and timestamps
- Log sequence metadata or bounded MVP log chunks
- Artifact metadata
- Encrypted secret envelopes
- Webhook delivery IDs
- Audit events

Redis must not be required to reconstruct job state after a restart.

### Redis

Redis may provide:

- Background work queues
- Short-lived coordination locks
- Rate-limit counters
- Live-log fan-out
- Cache entries

Redis data is disposable. Loss of Redis may delay processing but must not silently lose a workflow run.

### Object storage

S3-compatible storage contains:

- Build artifacts
- `.xcresult` bundles
- Archived logs after completion
- Future dependency caches
- Future diagnostic bundles

Runners upload large objects directly with short-lived pre-signed URLs. The server records metadata and enforces tenant ownership.

## Core domain model

```text
Organization
  ├── Members
  ├── GitHub installations
  ├── Runner pools
  │     └── Runners
  └── Repositories
        ├── Workflows
        ├── Secrets
        └── Workflow runs
              └── Jobs
                    ├── Attempts
                    ├── Steps
                    ├── Log chunks
                    └── Artifacts
```

Every tenant-owned record includes an organization identifier directly or through a mandatory foreign-key path.

## State machines

### Workflow run

```text
queued --> running --> succeeded
                   \-> failed
                   \-> cancelled
```

### Job

```text
queued --> leased --> running --> succeeded
   ^          |          |  \----> failed
   |          |          \-------> cancelled
   +----------+
      expired lease with an allowed retry
```

A job attempt owns a lease. When an expired job is retried, the new attempt receives a new lease ID. Messages from an older lease cannot mutate the current attempt.

### Runner

```text
offline <--> idle <--> busy
    \          |         /
     +------ disabled ---+
```

Runner status is derived from administrative state, heartbeat freshness, and active leases rather than trusted directly from a runner request.

## End-to-end pull-request flow

1. GitHub sends a signed pull-request webhook.
2. The server validates the signature and deduplicates the delivery ID.
3. Asynchronous processing identifies the installation, repository, and immutable head SHA.
4. The server fetches `.aci.yml` at that SHA.
5. The workflow parser validates and compiles it into normalized jobs.
6. A transaction creates the workflow run, jobs, and initial events.
7. The server creates a queued GitHub check run.
8. A compatible runner claims a job lease.
9. The runner requests a short-lived checkout credential when needed.
10. The runner checks out the SHA and executes the job.
11. Logs arrive in ordered batches and become visible in the dashboard.
12. The runner uploads configured artifacts.
13. The runner reports completion with the active lease ID.
14. The server commits the terminal state and updates GitHub.

## Workflow compilation

The public `.aci.yml` model and runner job specification are separate contracts.

Compilation performs:

- Schema-version validation
- Trigger evaluation
- Default application
- Runner-requirement normalization
- Step validation
- Secret-reference resolution without plaintext inclusion
- Artifact-path validation
- Timeout and limit enforcement

The stored job specification is immutable after queueing. Reruns create new workflow-run and job records.

## Logging model

Every log event contains:

- Job and attempt identifiers
- Lease ID
- Step identifier
- Monotonically increasing sequence number
- stdout or stderr stream
- Runner timestamp
- UTF-8 payload or explicit encoding marker

The server acknowledges the highest contiguous sequence it has persisted. The runner can safely resend unacknowledged batches. The UI orders logs by sequence rather than arrival time.

For the MVP, bounded chunks may be stored in PostgreSQL. Completed logs should later be compacted to object storage, retaining searchable metadata in PostgreSQL.

## Authentication boundaries

- **Users:** GitHub OAuth-based session or equivalent application session.
- **GitHub:** App private-key authentication, installation tokens, and signed webhooks.
- **Runners:** Revocable runner credentials exchanged from single-use registration tokens.
- **Jobs:** Random, expiring lease IDs bound to one runner and one attempt.
- **Artifacts:** Short-lived, tenant-scoped pre-signed URLs.

Authorization is enforced server-side for every record lookup. Identifier unpredictability is not an authorization mechanism.

## Deployment topology

### Development

- Server and web application on the developer machine
- PostgreSQL, Redis, and S3-compatible storage in containers
- Runner executing directly on a Mac

### Initial production

- Linux-hosted Vapor server instances
- Managed PostgreSQL and Redis
- S3-compatible managed object storage
- Next.js deployment
- User-managed Mac runners connecting outbound over HTTPS

### Hosted-runner future

- Apple-silicon Mac hosts
- Versioned macOS and Xcode images
- One ephemeral VM or equivalent clean environment per job
- Network and tenant isolation
- Automatic credential revocation and environment destruction

Apple's current licensing terms must be reviewed before providing commercial hosted macOS capacity.

## Android evolution

Android support extends capabilities rather than replacing the architecture:

```yaml
runs_on:
  os: linux
  arch: arm64
  capabilities:
    java: "21"
    android_sdk: "36"
```

Gradle execution, JUnit parsing, emulator management, APK/AAB artifacts, and Google Play delivery belong in Android adapters. The core scheduler, lease protocol, logs, secrets, and artifact model remain unchanged.

## Key architectural decisions

- Use HTTPS polling for the MVP; add Server-Sent Events or WebSockets where measurement shows value.
- Use PostgreSQL for durable state and concurrency control.
- Keep runner execution separate from the control-plane process.
- Start every command in an isolated process group and tear down the group on timeout or cancellation.
- Store public workflow input separately from compiled job specifications.
- Treat self-hosted runners as trusted by their owning organization but untrusted by ACI and other tenants.
- Defer hosted runners until self-hosted scheduling and cleanup are reliable.
