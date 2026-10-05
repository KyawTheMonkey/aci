# ACI Threat Model

## Purpose

ACI executes repository-controlled code on build machines and handles source credentials, signing assets, secrets, logs, and artifacts. This document identifies the initial trust boundaries, threats, mitigations, and accepted MVP risks.

This is a living engineering document, not a security certification.

## Security objectives

ACI must:

- Prevent one organization from accessing another organization's data or runners.
- Prevent a runner from claiming unauthorized jobs.
- Prevent an expired job attempt from changing current job state.
- Limit the value and lifetime of credentials delivered to runners.
- Keep protected secrets out of untrusted fork builds.
- Prevent artifacts and workspace paths from escaping their intended boundaries.
- Preserve an auditable history of privileged and state-changing operations.
- Make compromise of one self-hosted runner no more damaging than the permissions intentionally granted to that runner pool.

## Assets

High-value assets include:

- GitHub App private key
- GitHub installation tokens
- User sessions
- Runner registration and authentication credentials
- Job lease IDs
- Repository source code
- Environment secrets
- Signing certificates and private keys
- Provisioning profiles
- Build artifacts and `.xcresult` bundles
- Workflow and audit history
- Organization and repository authorization mappings

## Actors

### Legitimate user

An organization member configuring repositories, runners, workflows, secrets, and builds.

### Malicious repository contributor

A contributor able to modify source code or `.aci.yml`, including through a fork pull request. Repository access does not imply authorization to access CI secrets or host resources.

### Compromised runner

A registered machine or runner credential controlled by an attacker.

### Malicious organization member

An authenticated user attempting to exceed their role, extract secrets, register unauthorized machines, or access another tenant.

### External attacker

An unauthenticated party targeting public APIs, webhooks, sessions, runner endpoints, or infrastructure.

### Compromised dependency or toolchain

A malicious Swift package, npm package, build plugin, Homebrew package, Xcode tool, or runner update.

## Trust boundaries

```text
Internet
  |
  +-- GitHub webhooks ------> Control plane
  +-- User browser ---------> Web application and API
  +-- Registered runner ----> Runner API

Control plane
  |
  +-- PostgreSQL
  +-- Redis
  +-- Object storage
  +-- GitHub API

Runner machine
  |
  +-- ACI runner process
  +-- Untrusted repository checkout
  +-- Build tools and simulators
  +-- Local keychain and host resources
```

Self-hosted runners belong to the user's trust domain. ACI cannot protect files already accessible to the operating-system account running malicious repository code. Product documentation must make that boundary explicit.

## Threats and mitigations

### Forged GitHub webhooks

**Threat:** An attacker submits a fake push or pull-request event to create builds or manipulate checks.

**Mitigations:**

- Validate the signature against the raw request body before processing JSON.
- Use constant-time signature comparison.
- Reject missing or unsupported signature algorithms.
- Store and deduplicate GitHub delivery IDs.
- Confirm installation and repository authorization independently of payload claims.
- Process accepted events asynchronously after validation.

### Duplicate and reordered events

**Threat:** Retries or concurrent processing produce duplicate workflow runs or regress state.

**Mitigations:**

- Add unique constraints for provider delivery IDs and logical trigger identities.
- Make event handling idempotent.
- Validate all state transitions.
- Use database transactions for run and job creation.
- Never use event arrival order as the sole source of truth.

### Unauthorized runner registration

**Threat:** An attacker registers a machine into another organization's runner pool.

**Mitigations:**

- Require an authorized user to create a registration token.
- Bind each token to one organization and runner pool.
- Store only a token hash.
- Expire tokens quickly and allow one use.
- Display the resulting runner and registration audit event to administrators.

### Runner credential theft

**Threat:** A stolen credential impersonates a runner and claims jobs.

**Mitigations:**

- Store the local credential in macOS Keychain.
- Store a verification hash or appropriately protected credential server-side.
- Scope the credential to one runner and pool.
- Support immediate revocation.
- Rate-limit authentication failures.
- Record credential use and detect implausible concurrent connections.
- Consider client certificates or hardware-backed keys after the MVP.

### Job theft or replay

**Threat:** A runner modifies a job it does not own or replays messages from an earlier attempt.

**Mitigations:**

- Bind every mutation to runner ID, job ID, attempt ID, and lease ID.
- Use cryptographically random, expiring lease IDs.
- Reject messages from previous attempts.
- Rotate the lease ID for every retry.
- Make completion idempotent and reject conflicting terminal outcomes.

### Malicious workflow commands

**Threat:** Repository code reads host files, persists malware, attacks the network, or escapes cleanup.

**Mitigations:**

- Treat all workflow steps as arbitrary code execution.
- Document that self-hosted jobs inherit the runner account's operating-system access.
- Recommend dedicated, non-personal macOS accounts and machines.
- Execute each job in a fresh workspace.
- Terminate the complete process group on cancellation or timeout.
- Detect and clean surviving child processes.
- Minimize runner-service privileges.
- Introduce ephemeral VM isolation before offering multi-tenant hosted runners.

### Fork pull-request secret extraction

**Threat:** A contributor modifies a workflow to print or transmit protected secrets.

**Mitigations:**

- Classify fork pull requests as untrusted.
- Withhold protected secrets by default.
- Do not treat approval of repository code as implicit approval to expose secrets.
- Require an explicit trusted rerun policy if secret-bearing fork builds are ever supported.
- Show the trust level prominently in the UI.

### Secret exposure in logs

**Threat:** Commands print tokens, passwords, or signing data.

**Mitigations:**

- Redact known plaintext secret values at the runner and server.
- Prevent secrets from appearing in command arguments when possible.
- Mark secret environment variables as sensitive in diagnostics.
- Limit who can view and download logs.
- Apply retention policies.
- Treat redaction as defense in depth, not proof that arbitrary transformations of a secret are safe.

### Checkout credential leakage

**Threat:** Git credentials remain in configuration, process arguments, logs, or workspace files.

**Mitigations:**

- Mint short-lived, repository-scoped GitHub installation tokens.
- Deliver them only to a valid active lease.
- Prefer temporary credential helpers or protected headers over credential-bearing URLs.
- Remove helpers and Git configuration during cleanup.
- Redact credentials from logs.

### Path traversal and symbolic-link attacks

**Threat:** A workflow uploads host files or writes outside its workspace using `..`, absolute paths, or symbolic links.

**Mitigations:**

- Accept only workspace-relative artifact paths.
- Resolve canonical paths before access.
- Verify the canonical result remains under the canonical workspace root.
- Apply checks after following symbolic links.
- Reject device files, sockets, and unexpected special files.
- Enforce artifact count and size limits.

### Artifact cross-tenant access

**Threat:** A user guesses an artifact identifier or reuses a pre-signed URL belonging to another tenant.

**Mitigations:**

- Authorize artifact metadata through organization membership.
- Use opaque identifiers in addition to authorization.
- Scope storage keys by organization and repository.
- Use short-lived pre-signed URLs.
- Verify upload size and checksum.
- Prevent user-controlled storage keys.

### Object-storage abuse

**Threat:** A job uploads unlimited data, malicious content, or storage keys outside its allocation.

**Mitigations:**

- Set per-artifact and per-job limits.
- Restrict pre-signed requests to a specific key, method, expiration, and size where supported.
- Validate checksum and final metadata.
- Apply retention and lifecycle rules.
- Do not serve active content from the application origin.

### Command and environment injection

**Threat:** Untrusted values alter executable arguments, shell syntax, or environment behavior.

**Mitigations:**

- Represent executable, argument list, environment, and working directory separately.
- Use a shell only when the workflow explicitly defines a shell command.
- Never interpolate GitHub payload values into shell text without a defined escaping model.
- Restrict server-generated environment-variable names.
- Record the normalized specification used by the runner.

### Resource exhaustion

**Threat:** Jobs exhaust CPU, memory, disk, processes, logs, database rows, or API capacity.

**Mitigations:**

- Enforce job and step timeouts.
- Check disk space before claiming work.
- Limit concurrent jobs per runner and organization.
- Cap log-event and request sizes.
- Cap artifact count and bytes.
- Rate-limit public, user, and runner APIs separately.
- Add retention and cleanup jobs.
- Introduce OS- or VM-level resource controls for hosted runners.

### Control-plane command execution

**Threat:** Repository-controlled data reaches a server-side shell or process invocation.

**Mitigations:**

- Never execute workflow commands in the control plane.
- Parse workflows as data and compile them into an immutable job specification.
- Keep runner code and server code in separate executables and deployment identities.
- Review dependencies that evaluate templates or expressions.

### Signing-key compromise

**Threat:** An iOS signing certificate or private key is extracted from a runner or retained after a build.

**Mitigations:**

- Let early self-hosted users manage their existing signing environment.
- For managed signing, use a temporary keychain per job.
- Import only the certificates required by the job.
- Use short-lived keychain passwords generated for the attempt.
- Restore the keychain search list and delete temporary keychains afterward.
- Never share a signing environment between tenants.
- Audit every signing-secret access.

### Dependency and update compromise

**Threat:** A compromised ACI dependency or runner update executes attacker-controlled code.

**Mitigations:**

- Pin dependency versions and review lockfile changes.
- Run dependency and secret scanning.
- Sign runner releases.
- Verify update signatures before installation.
- Publish checksums through a separately protected channel.
- Protect release automation and signing keys with least privilege.

## Data protection

- Encrypt network traffic using TLS.
- Encrypt database and object-storage volumes using provider controls.
- Encrypt application secrets using envelope encryption.
- Keep encryption keys outside the database they protect.
- Avoid storing GitHub installation tokens; mint them when required.
- Apply explicit log and artifact retention periods.
- Remove sensitive values from structured application logs.
- Back up authorization and job-history data, and test restoration.

## Authorization rules

- Every repository belongs to exactly one ACI organization context.
- Every runner belongs to exactly one runner pool and organization.
- Jobs can target only runner pools authorized for their repository.
- A user must have an explicit organization role for administrative operations.
- Secrets are resolved by the server, never by trusting a runner-supplied repository ID.
- Artifact access is checked through the associated job, repository, and organization.
- Administrative support access is logged and minimized.

## Audit events

At minimum, record:

- User sign-in and session revocation
- GitHub installation and repository changes
- Runner-registration token creation
- Runner registration, disablement, and removal
- Secret creation, replacement, use, and deletion without storing plaintext
- Workflow-run cancellation and rerun
- Job assignment and lease changes
- Artifact deletion
- Role and membership changes
- Signing-asset access

Audit records must identify actor, action, target, organization, request ID, timestamp, and result.

## MVP accepted risks

The following risks may be accepted for a limited, invited-user MVP if documented:

- Self-hosted builds are not isolated from other data accessible to the runner's operating-system account.
- Exact-value log redaction cannot prevent every encoded or transformed secret disclosure.
- HTTPS bearer runner credentials are used before optional hardware-backed identity.
- Live logs may use polling rather than a dedicated streaming transport.
- Automatic code-signing asset management is not provided.
- Hosted multi-tenant execution is not provided.

These accepted risks do not permit cross-tenant authorization failures, plaintext secret storage, unsigned webhook processing, or execution of repository code in the control plane.

## Pre-release security checklist

- [ ] Webhook signature validation is covered by positive and negative tests.
- [ ] Duplicate GitHub deliveries create no duplicate runs.
- [ ] Tenant identifiers are included in authorization tests for every resource type.
- [ ] Registration tokens expire, are single-use, and are stored hashed.
- [ ] Disabled runner credentials cannot authenticate.
- [ ] Expired and mismatched leases cannot mutate a job.
- [ ] Fork pull requests receive no protected secrets.
- [ ] Known secrets are absent from runner, server, and web logs.
- [ ] Artifact traversal and symbolic-link attacks are rejected.
- [ ] Cancellation terminates descendant processes.
- [ ] Job, log, request, and artifact limits are enforced.
- [ ] Backups and restoration have been exercised.
- [ ] Dependency, container, and secret scans run in CI.
- [ ] Runner release artifacts are signed and verifiable.
- [ ] A documented incident-response and credential-revocation procedure exists.

## Review cadence

Review this threat model whenever ACI adds:

- Hosted runners
- Android emulators
- Managed signing
- Deployment credentials
- Additional source providers
- Reusable actions or third-party plugins
- Cross-organization runner sharing
- Billing or externally exposed usage APIs
