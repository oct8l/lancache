# LanCache Testing Guide

This document describes the comprehensive testing infrastructure for the LanCache project, designed to ensure reliability across ARM and AMD64 architectures while preventing broken releases.

## Overview

The testing system consists of three main workflows that provide comprehensive validation:

1. **PR Functionality Tests** - Validates every pull request
2. **Scheduled Build Tests** - Pre-validates before scheduled releases
3. **Performance Tests** - Manual performance and load testing

## Testing Workflows

### 1. PR Functionality Tests (`.github/workflows/test-pr-functionality.yml`)

**Triggers**: Automatically on all pull requests to `main`

**What it tests**:

- ✅ **Multi-architecture support**: Tests both AMD64 and ARM64 images
- ✅ **DNS resolution**: Validates all gaming CDN domains resolve correctly
- ✅ **Cache functionality**: Tests Steam, Epic Games, Origin, Battle.net, and direct downloads
- ✅ **Container health**: Ensures containers start and respond correctly
- ✅ **Cache persistence**: Verifies cache storage is working
- ✅ **Error detection**: Scans logs for critical errors

**Test scenarios**:

- Steam content caching (`steamcontent.com`)
- Epic Games launcher content (`download.epicgames.com`)
- Origin content (`origin-a.akamaihd.net`)
- Battle.net content (`blzddist1-a.akamaihd.net`)
- Direct download caching

**Architecture testing**:

- **AMD64**: Full functional test suite with all scenarios
- **ARM64**: Compatibility tests with core functionality (via QEMU emulation)

### 2. Scheduled Build Tests (`.github/workflows/test-scheduled-functionality.yml`)

**Triggers**:

- Scheduled: 30 minutes before main builds (4:00 AM on 1st and 15th of each month)
- Manual: `workflow_dispatch` with test level options

**Purpose**: Prevents broken scheduled releases by pre-testing with latest upstream changes

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

### 3. Performance Tests (`.github/workflows/performance-tests.yml`)

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
  - "functional-test-amd64"
  - "functional-test-arm64"
```

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
- **Root Cause**: DNS container not properly intercepting gaming CDN domains
- **Debug Steps**:
  - Check DNS container logs: `docker compose logs dns | grep "cache-domains"`
  - Verify environment variables: `docker compose exec dns env | grep LANCACHE`
  - Test DNS directly: `dig @127.0.0.1 -p 5353 steamcontent.com`
  - Check bind configuration: `docker compose exec dns cat /etc/bind/named.conf.local`
  - Verify cache domains directory: `docker compose exec dns ls -la /cache-domains/`
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
cp .github/workflows/test-pr-functionality.yml ./test-local.yml
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

1. **Add to PR tests** in `test-pr-functionality.yml`
2. **Update test matrix** to include new scenarios
3. **Add performance benchmarks** in `performance-tests.yml`
4. **Update documentation** in this file

### Improving Test Coverage

1. **Add new gaming services** as they become popular
2. **Include real download testing** with actual game content
3. **Add monitoring integration** for production validation
4. **Implement cross-platform testing** with self-hosted runners

For questions or improvements, please open an issue or submit a pull request.
