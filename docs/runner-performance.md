# ACI Runner Performance

## Decision summary

The current runner core is small and fast enough to continue into control-plane work, provided that performance remains a tested contract.

On the development Mac used for the first baseline, the release runner was a 3.41 MiB executable and a minimal one-step job stayed below 10 MiB peak resident memory. The measured runner-owned operations were in microseconds or low milliseconds. That means the current bottleneck for a real iOS job is `xcodebuild`, simulator startup, dependency resolution, checkout, provisioning, or machine availability—not the ACI orchestration layer.

This is not evidence that ACI is faster than a hosted CI product. Commercial vendors do not publish comparable runner-agent latency and resident-memory measurements, and their advertised build performance includes different hardware, images, caches, queueing, and virtualization. ACI should make a competitive claim only after executing the same public workload under controlled conditions.

The repository now treats performance in two ways:

1. Swift microbenchmarks compare a pull request with its base commit on the same Mac.
2. Absolute release-runner guardrails cap executable size, minimal-job latency, and peak resident memory.

Correctness remains a separate gate. A fast runner that leaks processes, checks out the wrong revision, or loses logs is a failed runner.

## Initial ACI baseline

Baseline date: 2026-10-07.

Host:

- Apple M3 Pro, 12 cores, 36 GB memory
- macOS 27.2
- Xcode 27.0
- Apple Swift 6.4
- Release configuration

These results are a diagnostic snapshot from one otherwise active development Mac. They must not be compared numerically with a vendor result collected on another machine.

| Runner-owned operation | p50 | p90 | Notable memory/allocation result |
| --- | ---: | ---: | ---: |
| Decode one-step job JSON | 10 µs | 11 µs | 8.2 KiB allocated per decode |
| Validate one-step job | 3.2 µs | 3.4 µs | 833 bytes allocated per validation |
| Decode 100-step/100-artifact JSON | 687 µs | 756 µs | 565 KiB allocated |
| Validate 100 steps and 100 artifacts | 452 µs | 524 µs | 124 KiB allocated |
| Orchestrate 100 successful stubbed steps | 6.0 ms | 6.6 ms | 3.86 MiB allocated; 541 KiB p50 RSS delta |
| Launch `/usr/bin/true` through `CommandExecutor` | 2.1 ms | 2.8 ms | 1.38 MiB p50 RSS delta for the benchmark process |
| Launch and drain 1 MiB of stdout | 3.3 ms | 4.2 ms | 787 KiB p50 RSS delta |

The separate release-process probe measured:

| Guarded property | Initial observation | Enforced ceiling |
| --- | ---: | ---: |
| `aci-runner` executable | 3.41 MiB | 8 MiB |
| First minimal-job invocation in a sample | 0.01–0.73 s across cold/warm local runs | 2.00 s |
| Warm minimal-job p50 | approximately 0.01 s; `/usr/bin/time` has coarse precision | 0.05 s |
| Warm minimal-job p95 | approximately 0.01 s; `/usr/bin/time` has coarse precision | 0.15 s |
| Maximum resident set | approximately 9.7 MiB | 32 MiB |

The Swift microbenchmark is the authoritative latency probe because it has high-resolution timing. The process-level probe exists primarily to catch binary-size and resident-memory explosions and intentionally has generous portability headroom.

One useful profile signal is the 3.86 MiB allocated while orchestrating 100 stubbed steps. `JobExecutor` currently copies and merges the host environment for every step. That is acceptable at roughly 6 ms for the maximum supported step count, so changing it now would be premature. If later protocol, logging, or artifact work increases this result materially, snapshotting the base environment once per job is the first optimization to evaluate.

## What the market publishes

Vendor documentation describes machine capacity and product behavior, but not a standardized runner-agent overhead benchmark. The table therefore compares disclosed execution environments and architecture rather than pretending that unlike numbers are equivalent.

| Platform | Published macOS capacity and behavior | Self-hosted option | Public agent-overhead/RSS result |
| --- | --- | --- | --- |
| ACI, current local baseline | Runs natively on the user's Apple-silicon Mac; no VM provisioning layer yet | Core product direction | Yes, in this repository, for the current executable |
| Bitrise | Current classes span M2 Pro/M4 machines from 4–5 CPU and 6 GB RAM through M4 Pro 14 CPU and 54 GB RAM. A resource-class ID may map to different hardware generations. Hosted builds use isolated VMs and self-hosted builds use a separate agent plus Bitrise CLI. | Yes | Not published in the cited documentation |
| CircleCI | Current macOS classes are `m4pro.medium` with 6 vCPU/28 GB and `m4pro.large` with 12 vCPU/56 GB. | Yes, including macOS through self-hosted runners | Not published in the cited documentation |
| GitHub Actions | Standard arm64 macOS is currently 3 M1 CPU, 7 GB RAM, and 14 GB SSD; the larger arm64 class is 5 M2 CPU, 14 GB RAM, and 14 GB SSD. Standard hosted jobs receive fresh VMs. | Yes | Not published as a standardized result |
| Xcode Cloud | Apple documents parallel testing and ephemeral build environments, but does not disclose a stable CPU/RAM class suitable for an agent benchmark. | No general-purpose local runner | Not published |
| Microsoft App Center | Build retired after 2025-03-31. Extended Analytics and Diagnostics support does not make App Center Build a current CI competitor. | Historical only | Not applicable |

Sources, retrieved 2026-10-07:

- [Bitrise build machine types](https://docs.bitrise.io/en/bitrise-platform/infrastructure/build-machines/build-machine-types)
- [Bitrise hosted build stacks](https://docs.bitrise.io/en/bitrise-platform/infrastructure/build-stacks/about-build-stacks)
- [Bitrise on-premise runner](https://docs.bitrise.io/en/bitrise-platform/infrastructure/running-bitrise-builds-on-premise)
- [CircleCI configuration and macOS resource classes](https://circleci.com/docs/reference/configuration-reference/)
- [GitHub-hosted runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [GitHub larger-runner specifications](https://docs.github.com/en/enterprise-cloud@latest/actions/reference/runners/larger-runners)
- [Xcode Cloud overview](https://developer.apple.com/xcode-cloud/)
- [Microsoft App Center retirement](https://learn.microsoft.com/en-us/appcenter/retirement)

The meaningful competitive lesson is that the major platforms win or lose much more than agent milliseconds. Pre-booted images, queue depth, machine class, dependency and Derived Data caches, simulator readiness, artifact transfer, and parallelism dominate mobile CI time-to-feedback.

## Measurement model

ACI records each part of the path separately so a faster machine cannot hide a slower runner:

```text
webhook received
      |
      v
queue wait  -->  runner assignment  -->  machine/VM ready
                                           |
                                           v
runner startup  -->  exact-SHA checkout  -->  command orchestration
                                                 |
                                                 v
                                      xcodebuild and simulator
                                                 |
                                                 v
                                      logs, results, artifacts
```

The current suite covers runner startup, job decoding and validation, in-process orchestration, subprocess launch, log draining, executable size, and resident memory. The iOS acceptance harness covers exact checkout and `xcodebuild` behavior, but it is not yet a timing gate because a developer laptop or shared hosted runner is too noisy for a reliable build-time ceiling.

When the server protocol exists, add timestamps for webhook receipt, job creation, lease availability, runner claim, checkout start/end, each step start/end, upload completion, and terminal acknowledgement. That will make queueing and control-plane overhead observable rather than inferred.

## Embedded benchmark suite

The isolated `apps/runner/Performance` package uses [Ordo One Benchmark](https://github.com/ordo-one/benchmark), pinned to version 1.36.2. It imports the local `ACIRunnerCore` library, while its benchmark dependencies stay out of the production runner package and are not linked into the `aci-runner` product.

The suite contains:

- One-step and maximum-size job JSON decoding.
- One-step and maximum-size semantic validation.
- Maximum-size job orchestration using an injected successful executor, which isolates ACI bookkeeping from process time.
- A real isolated `/usr/bin/true` launch through `CommandExecutor`.
- A real process producing 1 MiB of stdout to exercise pipe draining, incremental UTF-8 decoding, and log sequencing.

Run everything from the repository root:

```bash
./scripts/benchmark-runner.sh
```

Run only the high-resolution suite:

```bash
./scripts/benchmark-runner.sh micro --no-progress
```

Run only the release resource guard and save machine-readable output:

```bash
./scripts/benchmark-runner.sh resources \
  --output /tmp/aci-runner-resources.json
```

The resource limits can be overridden for an exploratory run with the `ACI_PERF_MAX_*` environment variables. Do not raise a committed budget merely to make a regression pass; profile the change and document why the product requirement changed.

## Pull-request policy

The `Runner performance` workflow runs on `macos-26` when runner, benchmark, performance-script, or performance-policy files change.

For an established suite it:

1. Builds the pull-request release executable and enforces the absolute resource ceilings.
2. Measures the base commit on the same hosted Mac.
3. Measures the pull-request commit.
4. Fails if the configured percentile tolerances detect a regression.
5. Uploads the process-level JSON result and writes the benchmark comparison to the job summary.

The first pull request that introduces the suite has no compatible base target, so it runs a bootstrap report plus all absolute guardrails. Later pull requests receive the base-versus-candidate gate.

In-code relative tolerances are:

| Area | p50 | p90 | p99 |
| --- | ---: | ---: | ---: |
| Decode and validation latency | 10% | 15% | Report only |
| Decode, validation, and orchestration allocation count | 10% | 15% | — |
| 100-step orchestration latency | 15% | 20% | Report only |
| OS process launch and 1 MiB log drain | 50% | 60% | Report only |

Allocated-byte totals, CPU time, context switches, syscalls, sampled RSS deltas, and p99 latency remain visible in reports but do not gate base-versus-head comparisons. Repeated identical-code trials showed that those measurements move with allocator, kernel, and host scheduling state. The more stable p50 and p90 latency, deterministic allocation count, and separate 32 MiB process RSS ceiling still guard efficiency without turning a single host outlier into a red pull request.

OS process measurements need much wider tolerances than pure Swift operations because hosted-machine load and kernel scheduling are outside ACI's control. Identical-code trials on the development Mac moved by up to 45% while the pure Swift medians remained stable. The relative OS gate therefore catches large regressions; the absolute 50 ms p50 minimal-job ceiling supplies the harder product budget. A failure is a prompt to reproduce on a quiet Mac and profile; it is not permission to automatically loosen the threshold.

After this workflow lands, configure the GitHub `Release runner guardrails` job as a required branch-protection check. A workflow file alone cannot prevent a maintainer from merging a red pull request.

For more stable long-term results, move the comparison job to a dedicated, thermally stable self-hosted Mac. The benchmark framework itself recommends dedicated hardware for reproducible CI comparisons. Continue using a dynamic base-versus-head comparison so macOS or Swift updates do not masquerade as ACI regressions.

## Fair cross-provider benchmark protocol

Use this protocol before publishing an ACI-versus-vendor comparison:

1. Publish the workload repository and pin its complete commit SHA.
2. Pin Xcode, Swift, iOS Simulator runtime, dependency lockfiles, destination, build settings, and test plan.
3. Select the closest disclosed hardware class and record CPU allocation, memory, disk, architecture, virtualization, and image identifier.
4. Measure queue wait, environment preparation, checkout, build/test, artifact upload, and total feedback time separately.
5. Run cold-cache and warm-cache experiments separately. Never average them together.
6. Execute at least 10 measured repetitions after a warm-up and report p50, p90, p95, and the complete range—not only the fastest run.
7. Keep logs and artifacts equivalent across providers; disabling work on one provider invalidates the comparison.
8. Record failures and retries. Reliability is part of performance.
9. Where the competing agent's RSS is not observable, mark it unavailable rather than estimating it.
10. Repeat on more than one day to expose queue and shared-host variability.

The existing `samples/ios/ACISample` project is intentionally tiny and is useful for runner-overhead sensitivity. Add a second representative application with Swift Package dependencies, multiple modules, unit tests, UI tests, and a meaningful Derived Data footprint before making market-facing build-speed claims.

## Performance roadmap

Keep the current implementation unless measurements justify change. Prioritize future work in this order:

1. Add protocol and daemon benchmarks when the long-lived runner service is introduced: idle RSS, claim latency, reconnect behavior, and memory after repeated jobs.
2. Add bounded log batching and backpressure tests before network streaming. A fast producer must not grow runner memory without limit when the server or network is slow.
3. Add artifact streaming benchmarks for large `.xcresult`, archive, and symbol bundles with a fixed memory ceiling.
4. Add exact-SHA cold and warm checkout benchmarks before repository caching. Cache correctness and credential isolation remain mandatory.
5. Add a dedicated-Mac nightly iOS workload for cold build, warm build, simulator boot, tests, and teardown.
6. Add soak tests of hundreds of sequential jobs to detect retained memory, leaked descendants, workspaces, and file descriptors.
7. Track scheduler queue-to-claim latency and runner utilization when the control plane exists.

The product performance objective is not merely “small agent.” It is predictable time-to-feedback with bounded memory, no lost work, and transparent attribution when a build is slow.
