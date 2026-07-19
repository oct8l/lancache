# LanCache Testing Guide

This document describes the comprehensive testing infrastructure for the LanCache project, designed to ensure reliability across ARM and AMD64 architectures while preventing broken releases.

## Overview

The testing system consists of four workflows that provide comprehensive validation:

1. **Validate** - Static validation of workflows, Compose, and Renovate config
2. **PR CI** - Validates every pull request and gates merges via `ci-gate`
3. **Release** - Builds, tests, and promotes release images via `release-gate`
4. **Performance Tests** - Manual performance and load testing

Candidate builds are shared: `build-candidates.yml` is a reusable workflow called by both **PR CI** and **Release**, so the same build logic (and its safety checks) runs regardless of which pipeline triggered it.

## Testing Workflows

### 1. Validate (`.github/workflows/validate.yml`)

**Triggers**: Called by PR CI for every pull request; also runs directly on push to `main`.

**What it tests**:

- `actionlint` (with its bundled ShellCheck) lints every workflow file and embedded shell.
- `docker compose config -q` validates the repository's user-facing `docker-compose.yml`.
- `jq` confirms `renovate.json` is valid JSON, and `renovate-config-validator --strict` validates it against the current Renovate schema.
- `git diff --check` catches whitespace/conflict-marker errors introduced by the change.

ShellCheck severity policy is documented in `.github/actionlint.yaml`: info/style findings are advisory; warning/error findings fail the job.

### 2. PR CI (`.github/workflows/pr-ci.yml`)

**Triggers**: Automatically on all pull requests to `main`. Superseded runs for the same PR are cancelled (PR-scoped concurrency group).

**Job graph**:

```text
validate
   |
build-candidates (same-repo PRs) --or-- fork-build-test (external fork PRs)
   |
   +--> functional-amd64
   +--> functional-arm64
   +--> component-generic
   +--> component-sniproxy
   +--> component-repo-compose
   +--> artifact-contracts
              |
           ci-gate
```

`ci-gate` is the single stable, non-matrix check intended to be required in branch protection. It explicitly evaluates the result of every job above (including the same-repo/fork branch that actually ran) and fails if any required job failed, was cancelled, or was skipped when it should have run.

**Same-repository PRs** (including Renovate): `build-candidates` builds all six images once per revision, pushes them to GHCR tagged `pr-<number>-<head-sha>` (immutable — a new commit gets a new tag rather than overwriting the previous revision's images), and captures each image's manifest digest as a job output. `functional-amd64`, `functional-arm64`, `component-generic`, `component-sniproxy`, `component-repo-compose`, and `artifact-contracts` all consume those exact digests, so updating a PR cannot cause a test to run against a stale image.

**External fork PRs**: GitHub always issues a read-only `GITHUB_TOKEN` for `pull_request` runs from forks, regardless of the `permissions:` declared in the workflow, so `build-candidates` cannot push to GHCR for fork PRs. `fork-build-test` runs instead: a local, AMD64-only build (`--load`, no `--push`, no registry login) with a basic heartbeat smoke test. Fork PRs do not get ARM64 or artifact-contract coverage.

**What `functional-amd64` checks** — a deterministic DNS + cache content integration test against a committed fixture topology (`tests/cache-integration/`), with no public CDN dependency:

- ✅ **RPZ / DNS coverage**: A representative set of cache-domain hostnames (Steam, Epic, Origin, Battle.net, Uplay) resolve to the monolithic container's IP; a non-cache-domain name (`example.com`) does not.
- ✅ **Cache miss then hit**: A client downloads known content through a cache-domain hostname; the response matches the fixture by checksum; the first request is a `MISS` and the second is a `HIT` (via nginx's `X-Upstream-Cache-Status` header).
- ✅ **Strong cache-hit proof**: With the origin container stopped, an eligible cached response still serves correctly with the right checksum.
- ✅ **Persistence**: After restarting monolithic (origin still stopped), the cached object remains usable.
- ✅ **Cache storage**: The cache directory contains data after priming.
- ✅ **`20_cache.conf` behavior**: `nocache=1` bypasses the cache (`BYPASS` status, origin re-fetched); range requests spanning a slice boundary return byte-correct content; 301/302 redirect responses are never cached (`MISS` on every request); concurrent first requests to the same uncached resource do not cause uncontrolled duplicate origin downloads (`proxy_cache_lock` dedup).
- ✅ **Container health / error detection**: Compose healthchecks and failure diagnostics (container logs, cache directory listing) are collected automatically on failure.
- ✅ **Dependency contracts**: `artifact-contracts` uploads and downloads a known file via `actions/upload-artifact` and `actions/download-artifact` so a Renovate PR bumping either action exercises it directly.

The origin (`tests/cache-integration/origin/`) is a small Python HTTP server serving a committed 2.5MB deterministic fixture (`tests/cache-integration/fixtures/fixture.bin`, regenerable via `generate-fixture.py`), with per-path hit counters used to prove miss/hit/bypass/dedup behavior independent of the `X-Upstream-Cache-Status` header. It is reached via a test-only nginx `location` block installed into the running monolithic container at test time (mirroring the technique the performance-tests workflow already uses) — the candidate DNS and monolithic images themselves are never modified.

**Architecture testing**:

- **AMD64**: Full deterministic cache integration test described above.
- **ARM64**: Real health/exit-state assertions (not just trusting `docker compose ps`) plus one DNS and one HTTP assertion against the actual candidate images, under QEMU emulation. A container that exits immediately, or never reaches `healthy`, fails the job.

> **Known gap (tracked for a follow-up PR)**: cache revalidation (`proxy_cache_revalidate`) and stale-response-on-upstream-error (`proxy_cache_use_stale`) are not yet covered. Both need a short-TTL cache configuration to force staleness within test time, which is a distinct environment from the single shared stack used above (see Phase 2.4's "simplify the matrix" guidance) — planned as a small dedicated addition rather than bundled here.

### Architecture and component coverage matrix

Every image is built for AMD64, ARM64, and ARMv7 (`build-candidates.yml`), which also verifies the published manifest actually contains all three platforms before returning digests — a build that silently drops a platform fails before it can reach a test, let alone promotion. Runtime coverage below is intentionally risk-proportionate: heavier for the images most central to correct caching, lighter for images that are mostly pass-through:

| Image | AMD64 | ARM64 | ARMv7 | Required behavior | Status |
| --- | --- | --- | --- | --- | --- |
| `lancache-ubuntu` | Build/smoke | Build/smoke | Build/smoke | Starts and runs a basic command | Manifest-verified; no dedicated runtime smoke test yet |
| `lancache-ubuntu-nginx` | Build/smoke | Build/smoke | Build/smoke | Nginx starts and config validates | Manifest-verified; no dedicated runtime smoke test yet |
| `lancache-monolithic` | Full integration | Core integration | Startup/heartbeat | DNS-to-cache and content behavior | AMD64 full + ARM64 core done; ARMv7 pending |
| `lancache-generic` | Startup/function | Startup/function | Startup | Derived image uses the intended candidate base | AMD64 done (`component-generic`); ARM64/ARMv7 pending |
| `lancache-sniproxy` | Startup/TLS path | Startup/TLS path | Startup | TLS pass-through reaches a controlled origin | AMD64 done (`component-sniproxy`); ARM64/ARMv7 pending |
| `lancache-dns` | Full DNS | Core DNS | Startup/query | Cacheable and forwarded lookups work | AMD64 full + ARM64 core done; ARMv7 pending |

`component-generic` verifies "derived image uses the intended candidate base" directly: it compares `lancache-generic`'s and `lancache-monolithic`'s `RootFS.Layers` and asserts monolithic's full layer list is an exact prefix of generic's — since layers are content-addressed, this proves generic's `FROM` really resolved to the tested candidate monolithic digest (not a stale or wrong base) without needing any custom build-time markers.

`component-sniproxy` (`tests/sniproxy/`) verifies "TLS pass-through reaches a controlled origin": a small self-signed-TLS nginx origin is registered under a network alias (`sniproxy-test.internal`); a client container first confirms the origin serves known content directly (sanity check that the fixture itself is correct), then uses `curl --connect-to sniproxy-test.internal:443:sniproxy:443` to force the same request's *TCP connection* through the candidate sniproxy container while keeping the *SNI hostname* unchanged. sniproxy resolves that hostname via Docker's embedded DNS (`UPSTREAM_DNS=127.0.0.11`) and passes the TLS bytes straight through to the origin without terminating TLS itself. The response must match the origin's known content exactly, proving the pass-through actually reached the intended destination rather than erroring, hanging, or connecting elsewhere.

`component-repo-compose` validates the repository's own user-facing `docker-compose.yml` — the file real users follow via `README.md` — rather than only the test-specific fixtures under `tests/`. It layers a CI-only override (`tests/repo-compose/ci-override.yml`, using the Compose Specification's `!override` merge tag so host ports are fully replaced rather than merged) on top of the real file to substitute the tested candidate digests and non-conflicting host ports (`15353`/`15380`/`15443` instead of `53`/`80`/`443`), writes a CI-safe `.env` (a real interface IP is required — `lancache-dns` rejects loopback addresses — detected via `ip -4 route get`), then asserts real DNS resolution and a working HTTP heartbeat through the started stack. `docker-compose.yml` itself is never edited.

> **Known gap (tracked for follow-up PRs)**: no image has ARMv7 runtime coverage yet, and `generic`/`sniproxy` have no ARM64 coverage either — ARMv7 QEMU emulation is slow enough that it's planned for the release-gate's deeper suite rather than every PR, per the plan's "fast required suite, deeper scheduled suite" principle.

### 3. Release (`.github/workflows/release.yml`)

**Triggers**: Push to `main`, push of a `v*.*.*` tag, manual `workflow_dispatch`, and the twice-monthly schedule (4:30 AM on the 1st and 15th). All four go through the exact same pipeline below — there is no separate, independently-scheduled publish path that can bypass testing.

This replaces the previous `build.yml` (which built and pushed unconditionally on push/tag/manual/its own schedule) and `test-scheduled-functionality.yml` (which ran on a second, separate schedule 30 minutes earlier and then called `gh workflow run build.yml` — a call that raced against `build.yml`'s own independent schedule trigger and could not actually block it if tests failed).

**Job graph**:

```text
resolve-upstream-shas
        |
build-candidates (reusable, shared with pr-ci.yml)
        |
        +--> functional-test
        +--> security-scan
                  |
             release-gate
                  |
               promote
                  |
          cleanup-candidates
```

1. **`resolve-upstream-shas`**: resolves each of the 6 upstream repos' current `master` commit SHA via `git ls-remote` (no full clone). Recorded in the job summary and uploaded as an `upstream-shas-<run-id>` artifact.
2. **`build-candidates`**: the same reusable workflow `pr-ci.yml` calls, given the exact resolved SHAs above (not a floating branch), tagged `candidate-<run-id>`. Base-image `FROM` lines are rewritten by `scripts/pin-base-image.sh`, which fails the build if its expected line doesn't appear in the target Dockerfile exactly once, rather than silently doing nothing (or the wrong thing) on a zero- or multi-match. This also overrides `lancache-dns`'s `dnstool` builder stage (`DNS_GO_BUILDER_IMAGE`), since upstream's Dockerfile pins an old `golang:1.23.1-alpine` with unpatched stdlib CVEs that upstream hasn't bumped — tracked as its own Renovate `customManager` in `renovate.json` so it updates the same way `TRIVY_VERSION` does.
3. **`functional-test`**: the identical `tests/cache-integration/run-integration-tests.sh` test PR CI runs, against the candidate digests.
4. **`security-scan`**: Trivy scan of the exact candidate digests (HIGH/CRITICAL). Advisory only for now, matching the previous behavior — see the known gap below.
5. **`release-gate`**: fails if `resolve-upstream-shas`, `build-candidates`, or `functional-test` did not succeed. A `security-scan` failure is logged as a warning but does not block.
6. **`promote`**: only runs if `release-gate` succeeded. Retags the tested candidate digests to `latest` (and to the pushed tag name, for a `v*.*.*` push) using `docker buildx imagetools create` — a registry-side manifest copy, not a rebuild — then verifies each promoted tag resolves back to the exact digest that was tested.
7. **`cleanup-candidates`**: best-effort deletion of old `candidate-<run-id>` package versions via the GitHub API, keeping the most recent few. Never deletes a version that also carries `latest` or a `vX.Y.Z` tag — `promote` retags by digest rather than rebuilding, so a just-promoted candidate version and the live release tag can be the same underlying version object (GHCR merges tags pointing at one digest). Marked `continue-on-error`, since the default `GITHUB_TOKEN` may not have package-delete rights depending on repository/package settings — if deletions consistently fail, that's a repository setting to confirm, not a workflow bug.

**Blocking criteria**:

- ❌ Failure to resolve upstream SHAs, build candidates, or pass the functional test blocks promotion entirely — no tag changes.
- ⚠️ Security vulnerabilities are logged as a warning but do not block (tracked as a known gap below).

> **Known gap (tracked for a follow-up PR)**: security scanning is advisory-only. Making it properly blocking needs a reviewed baseline (so pre-existing vulnerabilities in upstream base images don't permanently wedge every release) rather than either ignoring all findings or blocking on existing debt — see the plan's Phase 6.2.

### 4. Performance Tests (`.github/workflows/performance-tests.yml`)

**Triggers**: Manual only (`workflow_dispatch`)

**Test targets**:

- `latest`: Test current production images
- `pr`: Test PR images (if running from PR context)
- `custom`: Test specific image tags

**Load levels**:

- `light`: 10 connections, 30s duration
- `medium`: 50 connections, 60s duration
- `heavy`: 100 connections, 120s duration
- `stress`: 200 connections, 180s duration

**Performance metrics**:

- **DNS Performance**: Resolution time for gaming CDNs
- **HTTP Performance**: Basic response times
- **Cache Performance**: Cache miss vs hit performance comparison
- **Load Testing**: Concurrent request handling with Apache Bench and wrk
- **Resource Usage**: Memory and CPU consumption
- **Cache Efficiency**: Speed improvements and storage utilization

## How to Use

### For Pull Requests

**Automatic testing**: PR functionality tests run automatically when you create/update a PR.

**Manual performance testing**:

```bash
# Go to Actions tab > Performance and Load Tests > Run workflow
# Select "pr" as test target to test your PR images
```

### For Release Validation

**Scheduled validation**: The Release workflow runs automatically on the twice-monthly schedule, and also on every push to `main` or a `v*.*.*` tag.

**Manual validation**:

```bash
# Go to Actions tab > Release > Run workflow
```

### For Performance Analysis

**Run performance tests**:

```bash
# Go to Actions tab > Performance and Load Tests > Run workflow
# Configure:
# - Test target: latest, pr, or custom tag
# - Load level: light, medium, heavy, or stress
```

## Test Results

### PR Test Results

Results are displayed in:

- ✅ **GitHub step summaries** with detailed test results
- ✅ **PR comments** (if configured)
- ✅ **Check status** that can be made required for merging

### Release Results

- ✅ **Success**: `release-gate` passes and `promote` retags `latest` (and the pushed version tag, if any) to the tested candidate digests.
- ❌ **Failure**: `release-gate` fails and `promote` does not run — no tag changes. Detailed failure report in the job summary.

### Performance Test Results

Results include:

- **DNS resolution times** for all gaming CDNs
- **Cache hit/miss performance** comparisons
- **Load test metrics** (requests/sec, latency, throughput)
- **Resource utilization** (CPU, memory)
- **Historical artifacts** saved for 30 days

## Configuration

### Required Secrets

- `GITHUB_TOKEN`: Automatic (provided by GitHub)

### Optional Configuration

**Required branch protection**:

```yaml
# In repository settings > Branches > main
required_status_checks:
  - "ci-gate"
```

`ci-gate` is the only status check that should be required. It has a stable name independent of the functional-test matrix, and it explicitly fails if `validate`, the build, or any required functional/artifact job failed, was cancelled, or was skipped when it should have run.

**Notification setup** (optional):

```yaml
# Add to workflows for Slack/Discord notifications
- name: Notify on failure
  if: failure()
  # Add your notification action here
```

## Troubleshooting

### Common Issues

**1. ARM64 tests timeout**

- ARM64 emulation is slower, timeouts are set to 10 minutes
- Consider using self-hosted ARM runners for faster tests

**2. DNS resolution failures**

- **Symptom**: DNS queries return SOA records instead of cache IP
- **Root Cause**: DNS container not properly intercepting gaming CDN domains or testing wrong domains
- **Debug Steps**:
  - Check DNS container logs: `docker compose logs dns | grep "bootstrapping"`
  - Verify environment variables: `docker compose exec dns env | grep LANCACHE`
  - Test correct domains from inside container: `docker compose exec dns dig @127.0.0.1 +short download.epicgames.com`
  - Check RPZ configuration: `docker compose exec dns cat /etc/bind/cache/rpz.db | head -20`
  - Verify cache domains directory: `docker compose exec dns ls -la /opt/cache-domains/`
  - **Important**: Only test domains listed in `/etc/bind/cache/rpz.db`, not raw CDN domains
- **Solution**: Ensure proper environment variables and private IP addresses are used

**3. Cache performance variations**

- Performance tests include variance tolerance
- Check for GitHub Actions runner resource constraints

**4. Container startup issues**

- **Symptom**: DNS container constantly restarting with "IP address not valid" error
- **Root Cause**: LanCache DNS requires RFC 1918 private IP addresses
- **Solution**: Use proper private IPs:
  - ✅ `10.0.0.100` (Class A private)
  - ✅ `192.168.1.100` (Class C private)
  - ✅ `172.16.0.100` (Class B private)
  - ❌ `127.0.0.1` (localhost - not valid)
  - ❌ `8.8.8.8` (public IP - not valid)

**5. Security scan failures**

- Review Trivy output for actual vulnerabilities
- Update base images if critical vulnerabilities found

### Debug Commands

**View container logs**:

```bash
# Logs are automatically captured in test artifacts
# Download from Actions > Workflow run > Artifacts
```

**Manual test reproduction**:

```bash
# Use the same commands from workflows locally:
git clone <repo>
cd <repo>
cp .github/workflows/pr-ci.yml ./test-local.yml
# Edit test-local.yml to use local images
docker compose -f test-compose.yml up -d
```

## Best Practices

### For Contributors

1. **Monitor test results** in PR checks before requesting reviews
2. **Fix test failures** before marking PR as ready
3. **Run performance tests** for significant changes
4. **Check multi-arch compatibility** for base image changes

### For Maintainers

1. **Review test summaries** even for passing tests
2. **Investigate performance regressions** in performance test results
3. **Update test scenarios** as new gaming services are added
4. **Monitor resource usage** to optimize CI costs

## Architecture Details

### Test Infrastructure

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   PR CI         │    │  Release         │    │ Performance     │
│                 │    │                  │    │ Tests           │
│ • Cache Integ.  │    │ • Resolve SHAs   │    │ • Load Testing  │
│ • ARM64 Compat  │    │ • Security Scan  │    │ • Benchmarking  │
│ • ci-gate       │    │ • release-gate   │    │ • Resource Mon  │
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                    ┌──────────────────┐
                    │  Test Results    │
                    │                  │
                    │ • Step Summary   │
                    │ • Artifacts      │
                    │ • Status Checks  │
                    └──────────────────┘
```

### Test Coverage Matrix

| Component  | AMD64 | ARM64 | Load Test | Security |
| ---------- | ----- | ----- | --------- | -------- |
| DNS        | ✅    | ✅    | ✅        | ✅       |
| Monolithic | ✅    | ✅    | ✅        | ✅       |
| Steam      | ✅    | ⚠️    | ✅        | N/A      |
| Epic       | ✅    | ⚠️    | ✅        | N/A      |
| Origin     | ✅    | ⚠️    | ✅        | N/A      |
| Battle.net | ✅    | ⚠️    | ✅        | N/A      |

Legend: ✅ Full testing, ⚠️ Basic compatibility, N/A Not applicable

## Contributing to Tests

### Adding New Test Scenarios

1. **Add to PR tests** in `pr-ci.yml`
2. **Update test matrix** to include new scenarios
3. **Add performance benchmarks** in `performance-tests.yml`
4. **Update documentation** in this file

### Improving Test Coverage

1. **Add new gaming services** as they become popular
2. **Include real download testing** with actual game content
3. **Add monitoring integration** for production validation
4. **Implement cross-platform testing** with self-hosted runners

For questions or improvements, please open an issue or submit a pull request.
