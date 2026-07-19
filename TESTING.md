# LanCache Testing Guide

This document describes the comprehensive testing infrastructure for the LanCache project, designed to ensure reliability across ARM and AMD64 architectures while preventing broken releases.

## Overview

The testing system consists of four workflows that provide comprehensive validation:

1. **Validate** - Static validation of workflows, Compose, and Renovate config
2. **PR CI** - Validates every pull request and gates merges via `ci-gate`
3. **Scheduled Build Tests** - Pre-validates before scheduled releases
4. **Performance Tests** - Manual performance and load testing

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
   +--> artifact-contracts
              |
           ci-gate
```

`ci-gate` is the single stable, non-matrix check intended to be required in branch protection. It explicitly evaluates the result of every job above (including the same-repo/fork branch that actually ran) and fails if any required job failed, was cancelled, or was skipped when it should have run.

**Same-repository PRs** (including Renovate): `build-candidates` builds all six images once per revision, pushes them to GHCR tagged `pr-<number>-<head-sha>` (immutable — a new commit gets a new tag rather than overwriting the previous revision's images), and captures each image's manifest digest as a job output. `functional-amd64`, `functional-arm64`, and `artifact-contracts` all consume those exact digests, so updating a PR cannot cause a test to run against a stale image.

**External fork PRs**: GitHub always issues a read-only `GITHUB_TOKEN` for `pull_request` runs from forks, regardless of the `permissions:` declared in the workflow, so `build-candidates` cannot push to GHCR for fork PRs. `fork-build-test` runs instead: a local, AMD64-only build (`--load`, no `--push`, no registry login) with a basic heartbeat smoke test. Fork PRs do not get ARM64 or artifact-contract coverage.

**What the functional tests check**:

- ✅ **DNS resolution**: Validates gaming CDN domains resolve to the DNS container's configured IP.
- ✅ **Cache functionality**: Tests Steam, Epic Games, Origin, and Battle.net heartbeat responses.
- ✅ **Container health**: Ensures containers start, report healthy, and respond correctly.
- ✅ **Error detection**: Scans logs for critical errors.
- ✅ **Dependency contracts**: `artifact-contracts` uploads and downloads a known file via `actions/upload-artifact` and `actions/download-artifact` so a Renovate PR bumping either action exercises it directly.

**Architecture testing**:

- **AMD64**: Full functional test suite with all scenarios.
- **ARM64**: Compatibility tests with core functionality (via QEMU emulation).

> **Known gap (tracked for a follow-up PR)**: the functional tests above still only check the `/lancache-heartbeat` endpoint and DNS resolution — they do not yet download real content through the cache or assert cache hit/miss/persistence behavior. That deterministic content-cache test is planned separately.

### 3. Scheduled Build Tests (`.github/workflows/test-scheduled-functionality.yml`)

**Triggers**:

- Scheduled: 30 minutes before main builds (4:00 AM on 1st and 15th of each month)
- Manual: `workflow_dispatch` with test level options

**Purpose**: Prevents broken scheduled releases by pre-testing with latest upstream changes

Builds share the same GHCR registry build cache (`<image>:buildcache`) as `pr-ci.yml` and `build.yml`, so a cache warmed by any of the three benefits the others.

**Test levels**:

- `basic`: Core functionality only
- `comprehensive`: Full test suite including security scans
- `smoke`: Quick validation tests

**What it does**:

1. **Builds test images** with latest upstream changes
2. **Tests critical functionality** (DNS, HTTP, cache)
3. **Multi-architecture validation** (ARM64 compatibility)
4. **Security scanning** with Trivy vulnerability scanner
5. **Release decision**: Blocks or allows the main build based on results
6. **Automatic cleanup** of test images to save registry space

**Blocking criteria**:

- ❌ Core functionality failures (DNS, HTTP responses)
- ❌ Multi-architecture build/runtime failures
- ⚠️ Security vulnerabilities (warning only, doesn't block)

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

**Scheduled validation**: Runs automatically before scheduled builds.

**Manual validation**:

```bash
# Go to Actions tab > Scheduled Build Functionality Tests > Run workflow
# Choose test level: basic, comprehensive, or smoke
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

### Scheduled Test Results

- ✅ **Success**: Main build workflow is triggered automatically
- ❌ **Failure**: Build is blocked, detailed failure report in step summary
- 📧 **Notifications**: Can be configured to alert on failures

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
│   PR Tests      │    │  Scheduled Tests │    │ Performance     │
│                 │    │                  │    │ Tests           │
│ • AMD64 Matrix  │    │ • Pre-build      │    │ • Load Testing  │
│ • ARM64 Compat  │    │ • Security Scan  │    │ • Benchmarking  │
│ • 5 Scenarios   │    │ • Release Gate   │    │ • Resource Mon  │
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
