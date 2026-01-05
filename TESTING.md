# Testing Guide

For the full list of environment knobs and defaults, see [docs/ENV_REFERENCE.md](docs/ENV_REFERENCE.md).

## Runner Flags

- `VERBOSE=1` streams per-test logs and re-enables JSON tooling discovery logs (default is quiet). Applies to integration tests.
- `UNICODE=1` uses ✅/❌; default output is ASCII `[PASS]/[FAIL]`. Applies to integration tests.
- `MCPBASH_LOG_JSON_TOOL=log` forces JSON tooling detection logs even when `VERBOSE` is off.
- Integration runner: `MCPBASH_INTEGRATION_ONLY` / `MCPBASH_INTEGRATION_SKIP` filter which `test/integration/test_*.sh` scripts are executed (unknown names fail fast).
- Integration runner: `MCPBASH_INTEGRATION_TEST_TIMEOUT_SECONDS` enforces a per-test watchdog timeout (a timeout fails the test and reports `[TIMEOUT]`).
- Tar staging: CI turns it on (`MCPBASH_CI_MODE=1`); default is off locally. Override with `MCPBASH_STAGING_TAR=1` to force use or `=0` to disable.
- Quick start (all suites): `./test/run-all.sh` (add `--skip-integration`/`--skip-examples`/`--skip-stress`/`--skip-smoke` as needed).

## Linting

```
./test/lint.sh
```

## Smoke Tests (local quick check; not run in CI)

```
./test/smoke.sh
```

- Local precheck for init→list→call; CI relies on richer coverage in integration and compatibility suites.
- Scaffolded tools include a per-tool smoke script at `tools/<name>/smoke.sh`; run it after editing a tool to ensure stdout JSON is valid. Update its sample args if you change `tool.meta.json`.

## Unit Tests

```bash
# Install bats and helpers (first time only)
npm install

# Run all unit tests
./test/unit/run.sh

# Run specific test file(s)
./test/unit/run.sh json.bats
./test/unit/run.sh sdk_result
```

Unit tests use [bats-core](https://bats-core.readthedocs.io/) with 219 tests across 40 files. Includes coverage for the CLI `run-tool` entrypoint, SDK helpers, path normalization, locking, pagination, and JSON utilities.

- Parallel execution enabled when GNU parallel is installed (`brew install parallel`)
- CI outputs JUnit XML to `test-results/` for test result visualization
- Use `CI=true ./test/unit/run.sh` locally to generate JUnit output

## Integration Tests

```
./test/integration/run.sh
```

- Default output is concise with ASCII status markers; logs are captured under a suite temp dir and summarized at the end.
- `VERBOSE=1 ./test/integration/run.sh` streams each test log (prefixed with the test name) instead of only tailing on failures.
- `UNICODE=1 ./test/integration/run.sh` restores the ✅/❌ glyphs.
- JSON tooling discovery logs are suppressed during the suite by default; set `MCPBASH_LOG_JSON_TOOL=log` to re-enable them.

### Session Helper (Interactive Test Calls)

- For batch requests, prefer `test_run_mcp()` from `test/common/env.sh` (single process, NDJSON in/out).
- When you need sequential interactive calls without prebuilding request files, source `test/common/session.sh` and use `mcp_session_start`/`mcp_session_call`/`mcp_session_end`.
- Limitations: skips notifications, overwrites EXIT traps (clears them on cleanup), no timeout, minimal error handling.

## Examples Suite

```
./test/examples/run.sh
```

The examples runner now includes:
- `test_examples.sh` (protocol NDJSON harness across all examples)
- `test_run_tool_smoke.sh` (run-tool CLI smoke on the hello example with dry-run + roots)

## Compatibility Suite

```
./test/compatibility/run.sh
```

- TypeScript client check (`sdk_typescript.sh`) is opt-in; set `MCPBASH_RUN_SDK_TYPESCRIPT=1` to enable it. Without the flag, it is skipped to avoid pulling `npx ts-node` on environments where it is not already available.

## Stress Suite

```
./test/stress/run.sh
```

Regenerate this file with:
```
scripts/generate-testing-docs.sh > TESTING.md
```
