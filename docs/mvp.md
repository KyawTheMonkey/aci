# ACI MVP

## Objective

The ACI MVP proves one end-to-end product experience:

> A GitHub pull request automatically runs `xcodebuild test` on a registered Mac, streams its logs to ACI, and publishes the result as a GitHub check.

This vertical slice takes priority over broad CI feature coverage.

## Target user

The initial user is a native iOS developer or small iOS team that:

- Stores source code on GitHub.
- Has an Apple-silicon Mac available for builds.
- Wants a simpler iOS-focused alternative to a general-purpose CI platform.
- Is comfortable installing a trusted runner service on that Mac.

## Supported in the MVP

- GitHub App installation and repository selection
- Public and private GitHub repositories
- Apple-silicon self-hosted Mac runners
- One concurrent job per runner
- Push and pull-request triggers
- A repository-owned `.aci.yml` workflow
- Sequential `checkout` and `run` steps
- Exact commit SHA checkout
- `xcodebuild build` and `xcodebuild test`
- Build timeouts and cancellation
- Incremental log upload and dashboard display
- GitHub check-run status updates
- Repository-scoped secrets
- Artifact uploads, including `.xcresult`
- Basic test summary extraction

## Explicitly deferred

- ACI-hosted Mac runners
- Android runners
- GitLab and Bitbucket
- Matrix builds
- Parallel steps inside a job
- Reusable action marketplaces
- Visual workflow editing
- Deployment to App Store Connect
- Automatic code-signing management
- Advanced dependency caching
- Organization billing and usage metering
- Enterprise SSO and audit exports

## Milestone 0 — Foundation

### Tasks

- [ ] Establish the `apps/server`, `apps/runner`, and `apps/web` projects.
- [ ] Add PostgreSQL, Redis, and S3-compatible storage to local development.
- [ ] Add `.env.example` files without real credentials.
- [ ] Add health checks for the server and local dependencies.
- [ ] Add build and test commands for every application.
- [ ] Add CI for the ACI repository itself.

### Complete when

- The server health endpoint responds.
- The web application renders locally.
- The runner prints its version and capabilities.
- All local infrastructure starts with one documented command.

## Milestone 1 — Local runner execution

### Tasks

- [x] Define a versioned, normalized JSON job specification.
- [x] Discover macOS, architecture, Xcode, simulator, disk, and concurrency capabilities.
- [x] Create an isolated workspace for each job.
- [x] Clone a repository and check out an exact commit SHA.
- [x] Execute commands with an explicit executable, argument list, environment, and working directory.
- [x] Stream stdout and stderr as ordered events.
- [x] Record step start time, finish time, exit code, and outcome.
- [x] Implement job timeout and process-tree cancellation.
- [x] Remove the workspace after success, failure, or cancellation.

### Complete when

The following command can build a sample iOS project reliably:

```bash
aci-runner execute ./sample-job.json
```

The runner must correctly handle successful tests, compilation failure, test failure, timeout, cancellation, and invalid commit SHAs.

## Milestone 2 — Durable control plane

### Tasks

- [ ] Add organizations, users, repositories, and GitHub installations.
- [ ] Add runner pools, runners, and one-time registration tokens.
- [ ] Add workflow runs, jobs, steps, attempts, log chunks, and artifacts.
- [ ] Implement explicit state-transition validation.
- [ ] Create jobs transactionally.
- [ ] Implement capability-based job matching.
- [ ] Implement expiring job leases.
- [ ] Reconcile expired leases and offline runners.

### Complete when

An authenticated development endpoint or administrative command can create a queued job, and the database preserves its complete state history.

## Milestone 3 — Runner registration and dispatch

### Tasks

- [ ] Generate hashed, single-use runner registration tokens.
- [ ] Exchange a valid registration token for a revocable runner credential.
- [ ] Store the credential in macOS Keychain.
- [ ] Send runner and job heartbeats.
- [ ] Claim jobs using database locking and a lease ID.
- [ ] Upload ordered log batches.
- [ ] Report idempotent start and completion events.
- [ ] Propagate cancellation to the executing process tree.
- [ ] Add runner `register`, `start`, `stop`, `status`, `unregister`, and `diagnose` commands.
- [ ] Add optional `launchd` installation.

### Complete when

A server-created job is claimed by a separately running Mac runner, executed, logged, and completed without manual database changes.

## Milestone 4 — GitHub integration

### Tasks

- [ ] Create an ACI GitHub App.
- [ ] Request only repository metadata, contents, pull-request, and check permissions required by the MVP.
- [ ] Validate webhook signatures using the raw request body.
- [ ] Deduplicate events using GitHub delivery IDs.
- [ ] Process webhook events asynchronously.
- [ ] Handle installation and repository-selection changes.
- [ ] Handle supported push and pull-request events.
- [ ] Fetch `.aci.yml` from the exact commit SHA.
- [ ] Create and update GitHub check runs.
- [ ] Support check-run rerequests.

### Complete when

Opening or updating a pull request triggers one ACI run and produces one accurate GitHub check result, even when a webhook is delivered more than once.

## Milestone 5 — Workflow configuration

### Initial format

```yaml
version: 1

on:
  pull_request:
  push:
    branches:
      - main

jobs:
  test:
    runs_on:
      os: macos
      arch: arm64
      xcode: "18.0"

    timeout_minutes: 30

    steps:
      - checkout

      - run:
          name: Run tests
          command: |
            set -o pipefail
            xcodebuild test \
              -scheme Example \
              -destination 'platform=iOS Simulator,name=iPhone 17' \
              -resultBundlePath TestResults.xcresult

    artifacts:
      - TestResults.xcresult
```

### Tasks

- [ ] Define and document a strict schema.
- [ ] Reject unknown fields and unsupported schema versions.
- [ ] Apply deterministic defaults.
- [ ] Compile YAML into the normalized runner job specification.
- [ ] Preserve both source configuration and compiled specification for debugging.
- [ ] Support `checkout`, `run`, environment variables, timeouts, and artifact paths.
- [ ] Prevent configuration from selecting a runner outside the repository's authorized pools.

### Complete when

A repository can define its build and test commands without changing ACI server configuration.

## Milestone 6 — Web dashboard

### Pages

- [ ] Sign in with GitHub.
- [ ] Install or configure the GitHub App.
- [ ] List enabled repositories.
- [ ] List repository runs.
- [ ] Display run, job, and step details.
- [ ] Display incrementally updating logs.
- [ ] Cancel queued and running jobs.
- [ ] Manage runner pools and registration tokens.
- [ ] Manage repository settings and secrets.
- [ ] Download artifacts.

### Complete when

A user can install ACI, enable a repository, register a runner, inspect a run, and cancel it without using a private API or database command.

## Milestone 7 — Secrets, artifacts, and test results

### Tasks

- [ ] Encrypt repository secrets before persistence.
- [ ] Never return stored plaintext secrets through read APIs.
- [ ] Release only explicitly referenced secrets to a valid job lease.
- [ ] Withhold protected secrets from untrusted fork pull requests.
- [ ] Redact exact secret values from log output.
- [ ] Issue pre-signed artifact upload and download URLs.
- [ ] Reject artifact paths outside the job workspace.
- [ ] Store artifact size, checksum, content type, and retention date.
- [ ] Extract a test summary from `.xcresult` using the runner's installed Xcode tools.
- [ ] Apply artifact and log size limits.

### Complete when

A build can consume a repository secret without exposing it and can publish a downloadable `.xcresult` with a visible test summary.

## Milestone 8 — Production hardening

### Tasks

- [ ] Make webhook, log, start, completion, and cancellation operations idempotent.
- [ ] Test runner and server crashes at every job phase.
- [ ] Add request IDs, structured logs, metrics, and audit events.
- [ ] Distinguish user failures from infrastructure failures.
- [ ] Retry infrastructure failures only according to an explicit policy.
- [ ] Add API and runner-protocol version negotiation.
- [ ] Add rate limits and request-size limits.
- [ ] Test symlink and path-traversal defenses.
- [ ] Test log injection and secret-redaction behavior.
- [ ] Document backup and recovery procedures.

### Complete when

ACI passes the security checklist in [Threat Model](threat-model.md) and recovers predictably from runner, server, and network interruption tests.

## Release criteria

The MVP is ready for invited users when all of the following are true:

- A pull request reliably starts exactly one intended workflow run.
- A registered runner cannot claim jobs from an unauthorized pool.
- Duplicate messages do not create duplicate state transitions.
- Cancelling a job terminates its complete process tree.
- A runner crash produces a clear infrastructure failure or a policy-driven retry.
- GitHub check state agrees with ACI's terminal state.
- Secrets remain absent from API responses and test logs.
- Artifacts cannot escape the job workspace or organization boundary.
- Setup and recovery are documented for a developer who did not build ACI.

## Post-MVP sequence

1. Ephemeral hosted macOS runners
2. Image catalog and multiple Xcode versions
3. Dependency caching
4. App Store Connect deployment
5. Android runner capabilities and Gradle integration
6. Organization concurrency, quotas, and billing
7. Additional source-code providers
