# ACI — Agentic CI

ACI is an iOS-first continuous integration and delivery platform. It is designed for native mobile teams that want to run builds on their own Macs today and optionally use managed, ephemeral runners in the future.

> **Project status:** Early development. The documents in this repository describe the intended MVP and architecture; they do not imply that every feature is implemented.

## Product direction

ACI begins with one complete workflow:

1. A developer installs the ACI GitHub App on a repository.
2. A Mac is registered as a self-hosted runner.
3. A pull request creates an ACI workflow run.
4. The runner checks out the exact commit and runs `xcodebuild test`.
5. Logs stream to the ACI dashboard.
6. A GitHub check reports the final result.

The initial product supports native iOS projects. Android support will follow using the same platform-neutral job, scheduler, and runner concepts.

## Technology

- **Control plane:** Swift and Vapor
- **Web application:** Next.js, TypeScript, and the App Router
- **Runner:** Swift executable for macOS
- **Process execution:** Swift Subprocess with isolated process-group teardown
- **Primary database:** PostgreSQL
- **Transient coordination:** Redis
- **Artifacts:** S3-compatible object storage
- **Source provider:** GitHub App

## Architecture

ACI separates orchestration from execution:

```text
GitHub App and webhooks
          |
          v
Swift control plane ---- PostgreSQL
  API and scheduler       source of truth
          |
          +------------- Redis
          |               transient coordination
          v
Outbound HTTPS runner protocol
          |
          v
Self-hosted macOS runner ---- xcodebuild
          |
          v
S3-compatible artifact storage
```

The control plane never executes repository code. Builds run only on registered runner machines. See [Architecture](docs/architecture.md) for the component boundaries and execution flow.

## Repository layout

```text
aci/
├── apps/
│   ├── server/          # Swift/Vapor control plane
│   ├── runner/          # Swift macOS runner
│   └── web/             # Next.js dashboard
├── packages/
│   └── api/             # OpenAPI contract and generated clients
├── samples/
│   └── ios/ACISample/   # iOS simulator acceptance workload
├── scripts/
│   └── verify-runner-ios.sh
├── infrastructure/
│   ├── docker/          # Local development services
│   └── migrations/      # Infrastructure-managed migrations, if needed
└── docs/
    ├── architecture.md
    ├── mvp.md
    ├── runner-execution.md
    ├── runner-protocol.md
    └── threat-model.md
```

## MVP boundaries

The first release intentionally supports a narrow feature set:

- GitHub repositories
- Apple-silicon self-hosted Mac runners
- Push and pull-request triggers
- Sequential workflow steps
- `xcodebuild build` and `xcodebuild test`
- Live logs and cancellation
- GitHub check results
- Build artifacts and repository secrets

Hosted runners, Android, matrix builds, deployments, advanced caching, billing, and additional Git providers are deferred. See [MVP](docs/mvp.md) for milestones and completion criteria.

## Engineering principles

- PostgreSQL is the source of truth for every workflow and job state.
- A runner receives short-lived job leases, not ownership of scheduler state.
- Repository code is untrusted, including code from private repositories.
- Every build checks out an immutable commit SHA.
- Secrets are scoped, encrypted, redacted, and withheld from untrusted forks.
- Execution features remain platform-neutral; Xcode and Gradle are adapters.
- The simplest reliable protocol is preferred before introducing streaming complexity.

## Local runner development

The current runner accepts a normalized JSON job, validates it, optionally prepares an exact Git commit in an isolated workspace, and executes its command steps sequentially:

```bash
cd apps/runner
swift build
swift test
swift run aci-runner capabilities
swift run aci-runner execute --job Fixtures/Jobs/success.json
```

The local runner uses Swift Subprocess for process isolation, concurrent output collection, timeout enforcement, and process-group cancellation. It is an execution boundary, not a security sandbox. See [Runner execution](docs/runner-execution.md) for its lifecycle, guarantees, and current limitations.

Run the complete local iOS acceptance matrix with:

```bash
./scripts/verify-runner-ios.sh --all
```

The harness creates a temporary Git repository, checks out its exact commit through the runner, and exercises successful XCTest execution, compilation failure, test failure, timeout, and an unknown commit SHA.

## Documentation

- [MVP scope and milestones](docs/mvp.md)
- [System architecture](docs/architecture.md)
- [Runner execution](docs/runner-execution.md)
- [Runner protocol](docs/runner-protocol.md)
- [Threat model](docs/threat-model.md)

## Current implementation order

1. Execute a local JSON job, including an exact commit checkout, with the Swift runner.
2. Persist jobs and state transitions in the Vapor control plane.
3. Register a runner and dispatch jobs over HTTPS.
4. Integrate GitHub webhooks and check runs.
5. Add the Next.js dashboard.
6. Add secrets, artifacts, test results, and production hardening.
7. Introduce ephemeral hosted macOS runners.
8. Extend the runner model to Android.

The first major checkpoint is a server-created job that is claimed by a separate Mac runner, executes `xcodebuild test`, streams logs, and reaches a durable terminal state.

## References

- [Vapor documentation](https://docs.vapor.codes/)
- [Next.js App Router](https://nextjs.org/docs/app)
- [GitHub Apps documentation](https://docs.github.com/en/apps)
- [Apple Virtualization framework](https://developer.apple.com/documentation/virtualization)
