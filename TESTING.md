# Testing Guide

## Runner Flags

- `VERBOSE=1` streams per-test logs and re-enables JSON tooling discovery logs (default is quiet).
- `UNICODE=1` uses ✅/❌; default output is ASCII `[PASS]/[FAIL]`.
- `MCPBASH_LOG_JSON_TOOL=log` forces JSON tooling detection logs even when `VERBOSE` is off.

## Linting

```
./test/lint.sh
```

## Smoke Tests

```
./test/smoke.sh
```

## Unit Tests

```
./test/unit/run.sh
```

Includes coverage for the CLI `run-tool` entrypoint, SDK helpers, path normalization, locking, pagination, and JSON utilities.

## Integration Tests

```
./test/integration/run.sh
```

- Default output is concise with ASCII status markers; logs are captured under a suite temp dir and summarized at the end.
- `VERBOSE=1 ./test/integration/run.sh` streams each test log (prefixed with the test name) instead of only tailing on failures.
- `UNICODE=1 ./test/integration/run.sh` restores the ✅/❌ glyphs.
- JSON tooling discovery logs are suppressed during the suite by default; set `MCPBASH_LOG_JSON_TOOL=log` to re-enable them.

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

## Stress Suite

```
./test/stress/run.sh
```

Regenerate this file with:
```
scripts/generate-testing-docs.sh > TESTING.md
```
