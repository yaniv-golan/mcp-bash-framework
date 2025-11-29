# Testing Guide

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
