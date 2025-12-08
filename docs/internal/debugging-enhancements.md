# Debugging Enhancements Proposal

Ordered by impact on debuggability.

## 1. Structured tool stderr capture (`MCPBASH_TOOL_STDERR_CAPTURE`) — **Implemented**
- **Rationale:** Tool failures are opaque when stderr is discarded; attaching a bounded stderr tail accelerates root-cause discovery and shrinks repro time.
- **Status:** Implemented in `lib/tools.sh`; bounded tail added to `error.data._meta.stderr`/`stderrTail` (failures) and `result._meta.stderr` (success), gated by `MCPBASH_TOOL_STDERR_CAPTURE` with `MCPBASH_TOOL_STDERR_TAIL_LIMIT`.
- **Docs/Tests:** `docs/ERRORS.md`, `docs/DEBUGGING.md`, `docs/LOGGING.md`, `docs/BEST-PRACTICES.md` updated; integration coverage in `test/integration/test_tools_errors.sh`.

## 2. Timeout visibility (`MCPBASH_TOOL_TIMEOUT_CAPTURE`) — **Implemented**
- **Rationale:** Timeouts currently lack context, forcing guesswork. A short snapshot of what the tool last emitted helps pinpoint stalls.
- **Status:** Implemented in `lib/tools.sh`; timeout errors now include exit code and stderr tail (bounded) in `error.data` when enabled via `MCPBASH_TOOL_TIMEOUT_CAPTURE`.
- **Docs/Tests:** Covered in the same doc/test updates as #1.

## 3. Structured error surfaces (exit code, command trace) — **Implemented**
- **Rationale:** Consistent error payloads reduce debugging cycles and align with JSON-RPC expectations. This extends #1 by standardizing additional fields.
- **Status:** `exitCode` and `stderrTail` now land in `error.data` for failures; `traceLine` is included when tracing is enabled (`MCPBASH_TRACE_TOOLS`) or `$BASH_SOURCE:$LINENO` is available. Gated behind tracing.
- **Docs/Tests:** Documented alongside #1; integration tests updated.

## 4. Tool tracing toggle (`MCPBASH_TRACE_TOOLS`) — **Implemented**
- **Rationale:** `set -x` is invaluable for thorny tool bugs but too noisy to enable globally.
- **Status:** Implemented via opt-in env `MCPBASH_TRACE_TOOLS` with default `PS4='+ ${BASH_SOURCE[0]##*/}:${LINENO}: '` (override `MCPBASH_TRACE_PS4`). Traces go to per-invocation files under `MCPBASH_STATE_DIR`, capped by `MCPBASH_TRACE_MAX_BYTES` (tail retained). Shell tools are run with `bash -x` when detectable; tracing is gated and does not alter defaults.

## 5. Tool invocation logging — **Implemented**
- **Rationale:** Knowing which tool ran with what (sanitized) args helps reconstruct failure sequences.
- **Status:** Implemented logging at debug level with redacted details: arg count/bytes, metadata key count, roots count, timeout, trace flag; path only when verbose logging is enabled. No argument values are logged.

## 6. Environment doctor (`mcp-bash doctor`) — **Implemented**
- **Rationale:** Pre-flight checks prevent debugging dead-ends caused by bad shells, missing jq/gojq, or unwritable temp dirs.
- **Status:** `mcp-bash doctor` already exists with `--json`; enhanced to check `MCPBASH_TMP_ROOT` writability alongside bash/jq/gojq/quarantine. No network access; exits non-zero on failure with actionable messages.

## 7. CI-focused debugging bundle (`MCPBASH_CI_MODE` and artifacts)
- **Rationale:** CI jobs benefit from predictable log locations, terse summaries, and inline surfacing (e.g., GitHub annotations) to cut triage time.
- **Suggested implementation:**
  - Opt-in `MCPBASH_CI_MODE` that only sets defaults when unset: `MCPBASH_LOG_DIR` to CI-safe tmp/workspace; enable `MCPBASH_KEEP_LOGS=1` (with rotation/size caps to prevent disk bloat; new var to introduce); add timestamps; set `MCPBASH_LOG_LEVEL=info` by default with an override (e.g., `MCPBASH_CI_VERBOSE=1`) to elevate to `debug` while still redacting argument values/keys per logging rules.
  - Failure summary file under `MCPBASH_LOG_DIR/failure-summary.txt`: append tool name, sanitized arg shape/hash, exit code, capped/redacted stderr tail, timestamp. Prefer JSONL (machine-parseable) with a human-friendly helper; size-cap entries.
  - Environment snapshot (opt-in via CI mode): allowlisted fields only (bash version, OS, `set -o` status, cwd, redacted PATH summary). Never dump full env to avoid secrets leakage.
  - GitHub Actions annotations: gated on `GITHUB_ACTIONS=true` (and optionally an explicit toggle). Emit `::error` lines only when file/line is reliable (e.g., `traceLine` present from tracing/error data); exclude arg values.
  - Artifact layout: formalize a log tree under `MCPBASH_LOG_DIR` (summary + per-tool logs) with rotation/size caps; reuse existing redaction rules and avoid duplicating payload logs unless explicitly enabled (e.g., a dedicated `MCPBASH_CI_FULL_PAYLOADS` flag).
  - Delivery phases to reduce scope: (A) CI mode + log dir defaults + keep-logs; (B) failure summary + env snapshot; (C) GitHub annotations.

### Phase A status — **Partially Implemented**
- **Status:** `MCPBASH_CI_MODE` sets a CI-safe `MCPBASH_TMP_ROOT` (prefers `RUNNER_TEMP`, then `$GITHUB_WORKSPACE/.mcpbash-tmp`, else `TMPDIR`), sets `MCPBASH_KEEP_LOGS=true` when unset, and defaults log level to `info` if unspecified. Remaining Phase A items (log dir default, timestamps, CI verbose override) are pending.
