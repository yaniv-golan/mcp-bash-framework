# mcp-bash

## Scope and Goals
- Bash-only Model Context Protocol server verified on macOS Bash 3.2, Linux Bash ≥3.2, and experimental Git-Bash/WSL environments.
- Stable, versioned core under `bin/`, `lib/`, `handlers/`, `providers/`, and `sdk/` with extension hooks in `tools/`, `resources/`, `prompts/`, and `server.d/`.
- Targets MCP protocol version `2025-06-18` while supporting negotiated downgrades; stdout MUST emit exactly one JSON object per line.
- Repository deliverables include the full codebase, documentation, examples, and CI assets required to operate the server—no omissions.
- Transport support is limited to stdio; HTTP/SSE/OAuth transports remain out of scope for mcp-bash.

Future phases will extend protocol coverage while maintaining these scope guarantees.

## Developer Prerequisites
Local linting and CI expect a few command-line tools to be present:

- `shellcheck` – static analysis for all shell scripts.
- `shfmt` – enforces consistent formatting (used by `test/lint.sh`). Install via `go install mvdan.cc/sh/v3/cmd/shfmt@latest` (official upstream method) or your OS package manager.
- `gojq` (preferred) or `jq` – deterministic JSON tooling. The Go implementation behaves consistently across Linux/macOS/Windows and avoids known memory limits in the Windows `jq` build. Install with `go install github.com/itchyny/gojq/cmd/gojq@latest` and ensure `$HOME/go/bin` (or your `GOBIN`) is on `PATH`.

Without `shfmt`, the lint step fails immediately with "Required command \"shfmt\" not found in PATH".

## Runtime Detection
- JSON tooling detection order: `gojq` → `jq`. The first match enables the full protocol surface.
- Operators can set `MCPBASH_FORCE_MINIMAL=true` to deliberately enter the minimal capability tier even when tooling is present for diagnostics or compatibility checks.
- When no tooling is found, the core downgrades to minimal mode, exposing lifecycle, ping, and logging only.
- Legacy JSON-RPC batch arrays may be tolerated when `MCPBASH_COMPAT_BATCHES=true`, decomposing batches into individual requests prior to dispatch.

## Diagnostics & Logging
- The server honours the `MCPBASH_LOG_LEVEL` environment variable at startup (default `info`). Set `MCPBASH_LOG_LEVEL=debug` before launching `bin/mcp-bash` to surface discovery and subscription traces; higher levels (`warning`, `error`, etc.) suppress lower-severity messages.
- Clients can still adjust verbosity dynamically via `logging/setLevel`; both the environment variable and client requests flow through the same log-level gate.
- Deep payload tracing remains opt-in: `MCPBASH_DEBUG_PAYLOADS=true` writes per-message payload logs under `${TMPDIR}/mcpbash.state.*` for the session. When unset, no payload log files are created and the stdout guard operates silently.
- All diagnostics now route through the logging capability instead of raw `stderr` prints, keeping default test runs quiet unless the log level includes `debug`.

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

## Scaffolding Helpers
- `bin/mcp-bash scaffold tool <name>` creates `tools/<name>/` with an SDK-ready script, metadata (including `outputSchema`), and README pointers to follow-on examples.
- `bin/mcp-bash scaffold prompt <name>` builds `prompts/<name>/` with a starter template and metadata describing arguments, easing prompt registration with consistent schemas.
- `bin/mcp-bash scaffold resource <name>` provisions `resources/<name>/` backed by the `file` provider, wiring a `file://` URI to the generated content for immediate list/read coverage.

Edit the generated files, then run the relevant integration tests (`test/integration/test_tools.sh`, `test/integration/test_prompts.sh`, `test/integration/test_resources.sh`) to confirm compliance.

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

## Lifecycle & Ping
- `handlers/lifecycle.sh` validates `initialize` protocol versions, replies with negotiated capabilities, waits for the client’s `notifications/initialized` before accepting non-lifecycle traffic, and manages `shutdown`/`exit` sequencing.
- `handlers/ping.sh` returns immediate `{ "result": {} }` responses, providing a simple connectivity check.
- Core dispatch blocks non-lifecycle methods until `notifications/initialized` arrives and emits explicit errors when the server is uninitialized or shutting down, preserving lifecycle ordering guarantees.

## Tools
- `handlers/tools.sh` surfaces `tools/list` and `tools/call`, declining the methods in minimal mode.
- `lib/tools.sh` scans `tools/` (depth ≤3, skipping hidden files) honouring `NAME.meta.json` precedence over inline `# mcp:` annotations, writes `registry/tools.json`, and computes hash/timestamp data for pagination and listChanged semantics.
- Pagination cursors use opaque base64url payloads with `ver`, `collection`, `offset`, `hash`, and `timestamp`, and `tools/list` returns deterministic slices with `nextCursor` plus `total` counts.
- `tools/call` executes tool scripts with SDK env wiring, captures stdout/stderr, surfaces `_meta.stderr`, produces structured content when JSON tooling is available and metadata declares `outputSchema`, and propagates tool exit codes via `isError`.
- Manual overrides: executable `server.d/register.sh` can output a JSON payload with a `tools` array to replace auto-discovery entirely.

## Resources
- `handlers/resources.sh` supports `resources/list`, `resources/read`, and `resources/subscribe`/`unsubscribe`, returning capability errors when minimal mode is active.
- `lib/resources.sh` auto-discovers entries under `resources/`, honours metadata precedence, writes `registry/resources.json`, and uses portable allow-listed file providers with path normalization.
- Pagination reuse mirrors tools using `lib/paginate.sh`, providing deterministic cursors and `nextCursor` results while tracking registry hashes for listChanged notifications.
- `resources/read` resolves URIs via providers (baseline `providers/file.sh`) enforcing roots allow lists, returning MIME type hints and `_meta` diagnostics; subscriptions emit an immediate `notifications/resources/updated` snapshot and can be cancelled to clean state.
- Windows notes: file providers translate `C:\` drive prefixes into Git-Bash/MSYS `/c/...` form and honour `MSYS2_ARG_CONV_EXCL` so operators can opt out when needed.
- Future built-ins: git/https providers are stubbed for follow-up implementations.
- Manual overrides: executable `server.d/register.sh` can emit JSON `{ "tools": [...], "resources": [...], "prompts": [...] }` to bypass auto-discovery.

## Prompts
- `handlers/prompts.sh` exposes `prompts/list` and `prompts/get`, rejecting usage in minimal mode while offering rendered prompt content when JSON tooling is present.
- `lib/prompts.sh` scans `prompts/`, writes `registry/prompts.json`, and uses pagination helpers to provide stable cursors and `nextCursor` responses.
- Prompt templates honor argument schemas; rendering merges provided arguments into the template and returns both structured and text content.
- Manual overrides: `server.d/register.sh` may return a `prompts` array to override discovery.

## Additional Documentation
- [`docs/ERRORS.md`](docs/ERRORS.md)
- [`docs/SECURITY.md`](docs/SECURITY.md)
- [`docs/LIMITS.md`](docs/LIMITS.md)
- [`docs/WINDOWS.md`](docs/WINDOWS.md)
- [`docs/REMOTE.md`](docs/REMOTE.md)
- [`TESTING.md`](TESTING.md)
- [`SPEC-COMPLIANCE.md`](SPEC-COMPLIANCE.md)

## Completion
- `handlers/completion.sh` handles `completion/complete`, declining requests in minimal mode and limiting suggestions to 100 results.
- `lib/completion.sh` aggregates completion suggestions and reports `hasMore`, ready to integrate with richer providers while piggybacking on pagination helpers for cursor semantics.

## Logging
- `handlers/logging.sh` enforces RFC-5424 log levels via `logging/setLevel` and rejects invalid inputs with `-32602`, defaulting to `info` (overridable via `MCPBASH_LOG_LEVEL_DEFAULT`).
- `lib/logging.sh` tracks the active level and filters SDK-originated log notifications; worker subshells funnel JSON log entries through per-request streams that `lib/core.sh` emits after execution, keeping stdout protocol-safe.
# Trigger workflow update
