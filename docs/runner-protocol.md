# ACI Runner Protocol

## Purpose

This document defines the MVP protocol between the ACI control plane and a registered runner. The protocol is designed for outbound HTTPS communication from a runner behind NAT or a firewall.

The control plane owns scheduling state. A runner owns only the execution of a valid, active job lease.

## Protocol properties

- Versioned
- Authenticated
- Lease-based
- Idempotent where retries are expected
- Safe when messages are duplicated or reordered
- Compatible with intermittent runner connectivity
- Independent of Xcode- or Gradle-specific behavior

## Transport and headers

The MVP uses JSON over HTTPS.

Authenticated runner requests include:

```http
Authorization: Bearer <runner-credential>
Content-Type: application/json
X-ACI-Protocol-Version: 1
X-ACI-Request-ID: <uuid>
```

The server returns a supported protocol-version range when rejecting an incompatible runner.

Persistent WebSockets may later reduce polling and log latency, but they do not change the job-lease semantics described here.

## Runner lifecycle

```text
unregistered
     |
     | single-use registration token
     v
registered --> idle --> leased --> running
     ^          ^                    |
     |          +--------------------+
     |
     +--> disabled or unregistered
```

## Registration

An authenticated user first requests a one-time registration token:

```http
POST /v1/runner-registrations
```

The token is:

- Associated with one runner pool
- Stored by the server as a cryptographic hash
- Short-lived
- Single-use
- Shown only once

The runner exchanges it:

```http
POST /v1/runners/register
```

```json
{
  "registrationToken": "art_...",
  "name": "office-mac-mini",
  "runnerVersion": "0.1.0",
  "protocolVersion": 1,
  "capabilities": {
    "os": "macos",
    "osVersion": "26.0",
    "architecture": "arm64",
    "xcodeVersions": ["18.0"],
    "simulatorRuntimes": ["iOS 26.0"],
    "labels": ["self-hosted", "office"],
    "maxConcurrency": 1
  }
}
```

A successful response contains the runner ID and credential:

```json
{
  "runnerId": "runr_123",
  "credential": "arc_...",
  "heartbeatIntervalSeconds": 30,
  "jobPollIntervalSeconds": 5
}
```

The credential is returned only once and stored in macOS Keychain. The server stores only the value required to verify it.

## Runner heartbeat

```http
POST /v1/runners/{runnerId}/heartbeat
```

```json
{
  "runnerVersion": "0.1.0",
  "protocolVersion": 1,
  "capabilities": {},
  "activeJobs": [],
  "availableDiskBytes": 500000000000,
  "sentAt": "2026-10-05T11:00:00Z"
}
```

The response may contain:

- Updated polling intervals
- A minimum required runner version
- Administrative disablement
- A request to refresh capabilities

Runner online status is derived from heartbeat recency. A heartbeat does not grant authority to change a job state.

## Claiming a job

An idle runner requests compatible work:

```http
POST /v1/runners/{runnerId}/jobs/claim
```

```json
{
  "availableConcurrency": 1,
  "capabilitiesRevision": "sha256:..."
}
```

The server returns `204 No Content` when no job is available.

When a job is available, the server transactionally assigns it and returns:

```json
{
  "jobId": "job_123",
  "attemptId": "attempt_1",
  "leaseId": "lease_random_value",
  "leaseExpiresAt": "2026-10-05T11:02:00Z",
  "specification": {
    "version": 1,
    "repository": {
      "cloneURL": "https://github.com/example/ios-app.git",
      "commitSHA": "40-character-sha"
    },
    "workspace": {
      "cleanAfterExecution": true
    },
    "timeoutSeconds": 1800,
    "steps": [
      {
        "id": "test",
        "name": "Run tests",
        "kind": "command",
        "executable": "/bin/zsh",
        "arguments": ["-lc", "xcodebuild test -scheme Example"],
        "environment": {},
        "workingDirectory": null,
        "timeoutSeconds": 1500,
        "continueOnError": false
      }
    ],
    "artifacts": [
      {
        "path": "TestResults.xcresult",
        "required": false
      }
    ]
  }
}
```

The runner must reject unsupported specification versions before starting execution.

The clone URL is credential-free. It is compiled by the control plane from an authorized repository record rather than accepted directly from repository workflow text. The runner requires an absolute HTTPS URL and a complete lowercase 40-character commit SHA. Repository preparation is synthesized as the `checkout` result before the listed command steps.

## Checkout credentials

The stored job specification does not contain a long-lived provider credential.

Immediately before checkout, the runner requests a scoped credential using the active lease:

```http
POST /v1/jobs/{jobId}/checkout-credential
```

The server verifies runner identity, attempt, lease ID, lease expiry, repository authorization, and job state before returning a short-lived credential.

The runner must:

- Avoid placing credentials in command-line output.
- Avoid embedding credentials permanently in Git configuration.
- Redact the value from logs.
- Delete temporary credential helpers during cleanup.

Repository preparation initializes an empty workspace, fetches only the requested commit with no tags and depth one, and checks out that SHA in detached-HEAD mode. It does not resolve a branch or tag name at execution time. Host-level Git configuration and interactive credential prompts are disabled; future authenticated checkout will supply a temporary, lease-scoped mechanism explicitly.

## Starting execution

```http
POST /v1/jobs/{jobId}/start
```

```json
{
  "attemptId": "attempt_1",
  "leaseId": "lease_random_value",
  "startedAt": "2026-10-05T11:00:10Z"
}
```

The operation is idempotent for the same job, attempt, lease, and request ID. It fails when the lease is expired, revoked, or owned by another runner.

## Active-job heartbeat and cancellation

```http
POST /v1/jobs/{jobId}/heartbeat
```

```json
{
  "attemptId": "attempt_1",
  "leaseId": "lease_random_value",
  "currentStepId": "test",
  "lastLogSequence": 182,
  "sentAt": "2026-10-05T11:01:00Z"
}
```

The server renews the lease and responds:

```json
{
  "leaseExpiresAt": "2026-10-05T11:03:00Z",
  "cancelRequested": false
}
```

When `cancelRequested` is true, the runner:

1. Stops accepting new steps.
2. Sends `SIGTERM` to the job process group.
3. Waits for the configured grace period.
4. Sends `SIGKILL` if processes remain.
5. Performs workspace and secret cleanup.
6. Reports a cancelled terminal result.

The current local executor implements the same operating-system behavior through Swift Subprocess. Every command starts in a new session, and timeout or Swift task cancellation applies the graceful-then-forced teardown to the complete process group. See [Runner execution](runner-execution.md) for the in-process lifecycle. Server-driven cancellation will reuse that path when dispatch is implemented.

## Log upload

```http
POST /v1/jobs/{jobId}/logs
```

```json
{
  "attemptId": "attempt_1",
  "leaseId": "lease_random_value",
  "events": [
    {
      "sequence": 181,
      "stepId": "test",
      "stream": "stdout",
      "timestamp": "2026-10-05T11:01:01.120Z",
      "text": "Test Suite 'ExampleTests' started\n"
    }
  ]
}
```

The server responds with the highest contiguous sequence stored:

```json
{
  "acknowledgedThrough": 181
}
```

Rules:

- Sequence numbers are unique within one job attempt.
- The runner retains unacknowledged events within configured limits.
- The runner may resend a batch safely.
- The server deduplicates by attempt and sequence.
- The server and runner both apply defense-in-depth secret redaction.
- Invalid UTF-8 is encoded explicitly rather than silently corrupted.
- Per-event, per-request, and per-job size limits are enforced.

The local executor currently exposes UTF-8 text events and preserves valid scalars split across pipe buffers. The explicit binary/invalid-UTF-8 transport representation described above remains part of the future network protocol implementation.

## Step events

The runner reports step boundaries separately from raw logs:

```http
POST /v1/jobs/{jobId}/steps/{stepId}/start
POST /v1/jobs/{jobId}/steps/{stepId}/complete
```

Completion contains:

```json
{
  "attemptId": "attempt_1",
  "leaseId": "lease_random_value",
  "status": "failed",
  "exitCode": 65,
  "startedAt": "2026-10-05T11:00:20Z",
  "finishedAt": "2026-10-05T11:02:51Z"
}
```

Valid step outcomes are `succeeded`, `failed`, `cancelled`, `timed_out`, and `skipped`.

## Artifacts

The runner requests a pre-signed upload target:

```http
POST /v1/jobs/{jobId}/artifacts
```

The request includes:

- Lease and attempt IDs
- Relative workspace path
- Display name
- Byte size
- SHA-256 checksum
- Content type

The server returns a short-lived upload URL and artifact ID. After upload, the runner confirms completion. Artifact paths are resolved canonically and must remain inside the job workspace, including after symbolic-link resolution.

## Job completion

```http
POST /v1/jobs/{jobId}/complete
```

```json
{
  "attemptId": "attempt_1",
  "leaseId": "lease_random_value",
  "status": "failed",
  "failureKind": "user",
  "failureReason": "step_exit_code",
  "exitCode": 65,
  "lastLogSequence": 420,
  "startedAt": "2026-10-05T11:00:10Z",
  "finishedAt": "2026-10-05T11:03:10Z"
}
```

`failureKind` is one of:

- `user`: compilation, tests, workflow command, or project configuration
- `infrastructure`: runner, network, storage, or internal platform failure

Completion is idempotent for the same terminal payload. A conflicting second completion is rejected and audited.

## Lease expiry

When a lease expires:

1. The current attempt becomes interrupted.
2. The scheduler decides whether policy permits a new attempt.
3. A new attempt receives a new lease ID.
4. The former runner can no longer upload logs, artifacts, or completion for the job.

User failures are not retried automatically. Infrastructure failures may be retried within a configured attempt limit.

## Retry behavior

The runner retries only requests known to be safe:

- Heartbeats
- Log batches
- Idempotent step events
- Artifact confirmation
- Completion with the identical payload

Retries use exponential backoff with jitter and an upper bound. A runner does not claim additional work while the state of its current job is uncertain.

## Error model

Protocol errors return a stable machine-readable code:

```json
{
  "error": {
    "code": "lease_expired",
    "message": "The job lease is no longer active.",
    "requestId": "req_123"
  }
}
```

Example codes:

- `authentication_failed`
- `runner_disabled`
- `protocol_version_unsupported`
- `job_specification_unsupported`
- `lease_expired`
- `lease_mismatch`
- `invalid_state_transition`
- `payload_too_large`
- `rate_limited`

Messages are diagnostic and must not be parsed as protocol state.

## Minimum security requirements

- TLS is mandatory outside local development.
- Registration and runner credentials never appear in logs.
- Runner credentials are revocable and scoped to one runner.
- Lease IDs use cryptographically secure randomness.
- The server authorizes every job mutation against runner, attempt, and lease.
- Checkout credentials are short-lived and repository-scoped.
- Artifact paths are canonicalized and constrained to the workspace.
- Secrets are not provided to untrusted fork jobs.
- The runner removes temporary credentials, keychains, and workspaces after execution.
