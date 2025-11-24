# Architecture & Implementation Details

## Repository Layout
```
mcp-bash/
├─ bin/mcp-bash
├─ lib/
│  ├─ core.sh
│  ├─ rpc.sh
│  ├─ json.sh
│  ├─ lock.sh
│  ├─ timeout.sh
│  ├─ io.sh
│  ├─ ids.sh
│  ├─ paginate.sh
│  ├─ progress.sh
│  ├─ logging.sh
│  └─ spec.sh
├─ handlers/
│  ├─ lifecycle.sh
│  ├─ ping.sh
│  ├─ logging.sh
│  ├─ tools.sh
│  ├─ resources.sh
│  ├─ prompts.sh
│  └─ completion.sh
├─ providers/
├─ sdk/tool-sdk.sh
├─ server.d/
│  ├─ env.sh
│  └─ register.sh
├─ registry/
├─ tools/
├─ resources/
├─ prompts/
├─ test/
└─ docs/
```
This structure ensures the stable core modules live under `bin/` and `lib/`, protocol handlers sit in `handlers/`, extension points reside in `tools/`, `resources/`, `prompts/`, and `server.d/`, and runtime-generated registries remain isolated under `registry/` for exclusion from version control.

## Lifecycle Loop
- `bin/mcp-bash` sources the runtime, JSON, RPC, and core libraries, confirms stdout targets a terminal or pipe, and enters `mcp_core_run` for the main bootstrap loop.
- Incoming lines are sanitized (BOM stripped, whitespace trimmed) and compacted with the detected JSON tooling or validated through the built-in minimal tokenizer before dispatch.
- Arrays are rejected by default; when `MCPBASH_COMPAT_BATCHES=true`, batches are decomposed into individual requests prior to dispatch.
- Dispatch routes lifecycle, ping, logging, tools, resources, prompts, and completion methods, returning `-32601` for unknown methods while keeping notifications server-owned.
- Outbound messages pass through `rpc_send_line`, guaranteeing single-line JSON output with newline termination and carriage-return scrubbing to preserve the stdout contract.

## Concurrency Model
- Asynchronous requests (`tools/*`, `resources/*`, `prompts/get`, `completion/complete`) spawn background workers with request-aware state files under `${TMPDIR}/mcpbash.state.<ppid>.<bashpid>.<seed>`; synchronous lifecycle/logging/ping stay on the main loop.
- `lib/ids.sh` encodes JSON-RPC ids using base64url (SHA-256 fallback when >200 chars), tracks `pid.<encoded>` and `cancelled.<encoded>` markers, and ensures cleanup after completion.
- `lib/lock.sh` and `lib/io.sh` provide mkdir-based stdout locking under `${TMPDIR}/mcpbash.locks`, CR stripping, and UTF-8 validation so each response writes exactly one JSON line even under concurrency.
- Before emitting a response, workers acquire the stdout lock and drop results for requests marked cancelled, ensuring cancellation checks happen while holding the lock.
- `notifications/cancelled` mark cancellation files, deliver TERM → KILL escalation to the worker’s process group, and rely on `kill -0` probes to reap stale locks.

## Timeouts & Cleanup
- `lib/timeout.sh` implements `with_timeout <seconds> -- <command…>` with a watchdog that issues TERM then KILL if a worker outlives the timeout.
- Async dispatch paths consult `params.timeoutSecs` (when parsing JSON via jq/gojq) and wrap tool/resource/prompts/completion handlers with `with_timeout`, allowing per-request overrides while skipping minimal mode.
- `bin/mcp-bash` installs `trap 'mcp_runtime_cleanup' EXIT INT TERM`, ensuring `${TMPDIR}/mcpbash.state.*` and `${TMPDIR}/mcpbash.locks` are removed on shutdown.

## Handler Implementation Details

### Lifecycle & Ping
- `handlers/lifecycle.sh` validates `initialize` protocol versions, replies with negotiated capabilities, waits for the client’s `notifications/initialized` before accepting non-lifecycle traffic, and manages `shutdown`/`exit` sequencing.
- `handlers/ping.sh` returns immediate `{ "result": {} }` responses, providing a simple connectivity check.
- Core dispatch blocks non-lifecycle methods until `notifications/initialized` arrives and emits explicit errors when the server is uninitialized or shutting down, preserving lifecycle ordering guarantees.

### Tools
- `handlers/tools.sh` surfaces `tools/list` and `tools/call`, declining the methods in minimal mode.
- `lib/tools.sh` scans `tools/` (depth ≤3, skipping hidden files) honouring `NAME.meta.json` precedence over inline `# mcp:` annotations, writes `registry/tools.json`, and computes hash/timestamp data for pagination and listChanged semantics.
- Pagination cursors use opaque base64url payloads with `ver`, `collection`, `offset`, `hash`, and `timestamp`, and `tools/list` returns deterministic slices with `nextCursor` plus `total` counts.
- `tools/call` executes tool scripts with SDK env wiring, captures stdout/stderr, surfaces `_meta.stderr`, produces structured content when JSON tooling is available and metadata declares `outputSchema`, and propagates tool exit codes via `isError`.
- Manual overrides: executable `server.d/register.sh` can output a JSON payload with a `tools` array to replace auto-discovery entirely.

### Resources
- `handlers/resources.sh` supports `resources/list`, `resources/read`, and `resources/subscribe`/`unsubscribe`, returning capability errors when minimal mode is active.
- `lib/resources.sh` auto-discovers entries under `resources/`, honours metadata precedence, writes `registry/resources.json`, and uses portable allow-listed file providers with path normalization.
- Pagination reuse mirrors tools using `lib/paginate.sh`, providing deterministic cursors and `nextCursor` results while tracking registry hashes for listChanged notifications.
- `resources/read` resolves URIs via providers (baseline `providers/file.sh`) enforcing roots allow lists, returning MIME type hints and `_meta` diagnostics; subscriptions emit an immediate `notifications/resources/updated` snapshot and can be cancelled to clean state.
- Windows notes: file providers translate `C:\` drive prefixes into Git-Bash/MSYS `/c/...` form and honour `MSYS2_ARG_CONV_EXCL` so operators can opt out when needed.
- Future built-ins: git/https providers are stubbed for follow-up implementations.
- Manual overrides: executable `server.d/register.sh` can emit JSON `{ "tools": [...], "resources": [...], "prompts": [...] }` to bypass auto-discovery.

### Prompts
- `handlers/prompts.sh` exposes `prompts/list` and `prompts/get`, rejecting usage in minimal mode while offering rendered prompt content when JSON tooling is present.
- `lib/prompts.sh` scans `prompts/`, writes `registry/prompts.json`, and uses pagination helpers to provide stable cursors and `nextCursor` responses.
- Prompt templates honor argument schemas; rendering merges provided arguments into the template and returns both structured and text content.
- Manual overrides: `server.d/register.sh` may return a `prompts` array to override discovery.

### Completion
- `handlers/completion.sh` handles `completion/complete`, declining requests in minimal mode and limiting suggestions to 100 results.
- `lib/completion.sh` aggregates completion suggestions and reports `hasMore`, ready to integrate with richer providers while piggybacking on pagination helpers for cursor semantics.

### Logging
- `handlers/logging.sh` enforces RFC-5424 log levels via `logging/setLevel` and rejects invalid inputs with `-32602`, defaulting to `info` (overridable via `MCPBASH_LOG_LEVEL_DEFAULT`).
- `lib/logging.sh` tracks the active level and filters SDK-originated log notifications; worker subshells funnel JSON log entries through per-request streams that `lib/core.sh` emits after execution, keeping stdout protocol-safe.
