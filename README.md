# mcp-bash

## Scope and Goals (Spec §1)
- Bash-only Model Context Protocol server verified on macOS Bash 3.2, Linux Bash ≥3.2, and experimental Git-Bash/WSL environments (Spec §1 bullet 1).
- Stable, versioned core under `bin/`, `lib/`, `handlers/`, `providers/`, and `sdk/` with extension hooks in `tools/`, `resources/`, `prompts/`, `server.d/` (Spec §1 bullet 2).
- Targets MCP protocol version `2025-06-18` while supporting negotiated downgrades; stdout MUST emit exactly one JSON object per line (Spec §1 bullets 3–4).
- Repository deliverables include full codebase, documentation, examples, and CI assets defined in the technical specification—no omissions (Spec §1 bullet 5).
- Transport support is limited to stdio; HTTP/SSE/OAuth transports remain out of scope for mcp-bash (Spec §1 bullet 6).

Further phases will implement the remaining specification sections in order, maintaining these scope guarantees throughout the project.

## Runtime Detection (Spec §2)
- JSON tooling detection order: `gojq` → `jq` → system `python`/`python3`; first match enables the full protocol surface, with Python providing reduced ergonomics (Spec §2 paragraph “Utilities”).
- Operators can set `MCPBASH_FORCE_MINIMAL=true` to deliberately enter the minimal capability tier even when tooling is present, matching the diagnostics guidance in Spec §2.
- When no tooling is found, the core downgrades to minimal mode, exposing lifecycle, ping, and logging only as outlined in the Spec §2 minimal-mode surface table.
- Legacy JSON-RPC batch arrays may be tolerated when `MCPBASH_COMPAT_BATCHES=true`, echoing the compatibility toggle described in Spec §2 “Legacy batch compatibility”.

## Diagnostics & Logging (Spec §13)
- The server honours the `MCPBASH_LOG_LEVEL` environment variable at startup (default `info`). Set `MCPBASH_LOG_LEVEL=debug` before launching `bin/mcp-bash` to surface discovery and subscription traces; higher levels (`warning`, `error`, etc.) suppress lower-severity messages.
- Clients can still adjust verbosity dynamically via `logging/setLevel`; both the environment variable and client requests flow through the same log-level gate.
- Deep payload tracing remains opt-in: `MCPBASH_DEBUG_PAYLOADS=true` writes per-message payload logs under `${TMPDIR}/mcpbash.state.*` for the session. When unset, no payload log files are created and the stdout guard operates silently.
- All diagnostics now route through the logging capability instead of raw `stderr` prints, keeping default test runs quiet unless the log level includes `debug`.

## Repository Layout (Spec §3)
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
Structure mirrors the Spec §3 repository contract: stable core modules live under `bin/` and `lib/`, protocol handlers sit in `handlers/`, extension points reside in `tools/`, `resources/`, `prompts/`, and `server.d/`, and runtime-generated registries are isolated under `registry/` for exclusion from version control.

## Lifecycle Loop (Spec §4)
- `bin/mcp-bash` now sources the runtime, JSON, RPC, and core libraries, confirms stdout targets a terminal or pipe, and enters `mcp_core_run` for the Spec §4 bootstrap.
- Incoming lines are sanitized (BOM stripped, whitespace trimmed) and compacted with the detected JSON tooling or validated through the built-in minimal tokenizer before dispatch (Spec §4 bullet 2 paired with Spec §2 minimal-mode requirements).
- Arrays are rejected by default; when `MCPBASH_COMPAT_BATCHES=true`, batches are decomposed into individual requests prior to dispatch (Spec §4 bullet 2 and the legacy compatibility note).
- Dispatch routes lifecycle, ping, logging, tools, resources, prompts, and completion methods, returning `-32601` for unknown methods while keeping notifications server-owned (Spec §4 bullet 3).
- Outbound messages pass through `rpc_send_line`, guaranteeing single-line JSON output with newline termination and carriage-return scrubbing to preserve the Spec §4 stdout contract (Spec §4 bullet 4).

## Concurrency Model (Spec §5)
- Asynchronous requests (`tools/*`, `resources/*`, `prompts/get`, `completion/complete`) spawn background workers with request-aware state files under `${TMPDIR}/mcpbash.state.<ppid>.<bashpid>.<seed>`; synchronous lifecycle/logging/ping stay on the main loop.
- `lib/ids.sh` encodes JSON-RPC ids using base64url (SHA-256 fallback when >200 chars), tracks `pid.<encoded>` and `cancelled.<encoded>` markers, and ensures cleanup after completion.
- `lib/lock.sh` and `lib/io.sh` provide mkdir-based stdout locking under `${TMPDIR}/mcpbash.locks`, CR stripping, and UTF-8 validation so each response writes exactly one JSON line even under concurrency.
- Before emitting a response, workers acquire the stdout lock and drop results for requests marked cancelled, aligning with the Spec §5 requirement that cancellation checks happen while holding the lock.
- `notifications/cancelled` mark cancellation files, deliver TERM → KILL escalation to the worker’s process group, and rely on `kill -0` probes to reap stale locks, matching the cancellation flow defined in Spec §5.

## Timeouts & Cleanup (Spec §6)
- `lib/timeout.sh` implements `with_timeout <seconds> -- <command…>` with a watchdog that issues TERM then KILL if a worker outlives the timeout, matching Spec §6 bullet 1.
- Async dispatch paths consult `params.timeoutSecs` (when parsing JSON via jq/gojq/Python) and wrap tool/resource/prompts/completion handlers with `with_timeout`, allowing per-request overrides while skipping minimal mode (Spec §6 bullet 2).
- `bin/mcp-bash` installs `trap 'mcp_runtime_cleanup' EXIT INT TERM`, ensuring `${TMPDIR}/mcpbash.state.*` and `${TMPDIR}/mcpbash.locks` are removed on shutdown (Spec §6 bullet 3).

## Lifecycle & Ping (Spec §8)
- `handlers/lifecycle.sh` validates `initialize` protocol versions, replies with negotiated capabilities, waits for the client’s `notifications/initialized` before accepting non-lifecycle traffic, and manages `shutdown`/`exit` sequencing (Spec §8 lifecycle row, plus Spec §4 workflow).
- `handlers/ping.sh` returns immediate `{ "result": {} }` responses, providing a connectivity check consistent with Spec §8 ping requirements.
- Core dispatch blocks non-lifecycle methods until `notifications/initialized` arrives and emits explicit errors when the server is uninitialized or shutting down, ensuring Spec §8’s ordering guarantees.

## Tools (Spec §8–§11)
- `handlers/tools.sh` surfaces `tools/list` and `tools/call`, declining the methods in minimal mode (Spec §8 tools row & Spec §2 minimal-mode table).
- `lib/tools.sh` scans `tools/` (depth ≤3, skipping hidden files) honouring `NAME.meta.yaml` precedence over inline `# mcp:` annotations, writes `registry/tools.json`, and computes hash/timestamp data for pagination/listChanged semantics (Spec §9 discovery steps 1–7).
- Pagination cursors follow Spec §11 (opaque base64url payloads with `ver`, `collection`, `offset`, `hash`, `timestamp`), and `tools/list` returns deterministic slices with `nextCursor` plus `total` counts.
- `tools/call` executes tool scripts with SDK env wiring, captures stdout/stderr, surfaces `_meta.stderr`, produces structured content when JSON tooling is available and metadata declares `outputSchema`, and propagates tool exit codes via `isError` (Spec §5 cancellation integration, Spec §16 failure handling).
- Manual overrides: executable `server.d/register.sh` can output a JSON payload with a `tools` array to replace auto-discovery entirely (Spec §9 manual registration).

## Resources (Spec §8–§12)
- `handlers/resources.sh` supports `resources/list`, `resources/read`, and `resources/subscribe`/`unsubscribe`, returning capability errors when minimal mode is active (Spec §8 resources row & Spec §2 table).
- `lib/resources.sh` auto-discovers entries under `resources/`, honours metadata precedence, writes `registry/resources.json`, and uses portable allow-listed file providers with path normalization aligned to Spec §12 portability guidance.
- Pagination reuse mirrors tools using `lib/paginate.sh`, providing deterministic cursors and `nextCursor` results while tracking registry hashes for listChanged notifications (Spec §11).
- `resources/read` resolves URIs via providers (baseline `providers/file.sh`) enforcing roots allow lists, returning MIME type hints and `_meta` diagnostics; subscriptions emit an immediate `notifications/resources/updated` snapshot and can be cancelled to clean state (Spec §8 + Spec §16 error handling expectations).
- Windows notes: file providers translate `C:\` drive prefixes into Git-Bash/MSYS `/c/...` form and honour `MSYS2_ARG_CONV_EXCL` so operators can opt out when needed (Spec §12).
- Future built-ins: git/https providers are stubbed for follow-up implementations described in Spec §19.
- Manual overrides: `server.d/register.sh` may supply a `resources` array, bypassing discovery (Spec §9 manual registration).
- Manual overrides: executable `server.d/register.sh` can emit JSON `{ "tools": [...], "resources": [...], "prompts": [...] }` to bypass auto-discovery (Spec §9 manual registration).

## Prompts (Spec §8–§10)
- `handlers/prompts.sh` exposes `prompts/list` and `prompts/get`, rejecting usage in minimal mode while offering rendered prompt content when JSON tooling is present (Spec §8 prompts row & Spec §2).
- `lib/prompts.sh` scans `prompts/` (metadata precedence mirroring Spec §9), writes `registry/prompts.json`, and uses pagination helpers to provide stable cursors/`nextCursor` responses (Spec §11).
- Prompt templates honor argument schemas; rendering merges provided arguments into the template and returns both structured and text content, matching Spec §10 SDK guidance for prompts.
- Manual overrides: `server.d/register.sh` may return a `prompts` array to override discovery (Spec §9 manual registration).

## Additional Documentation
- [`docs/ERRORS.md`](docs/ERRORS.md)
- [`docs/SECURITY.md`](docs/SECURITY.md)
- [`docs/LIMITS.md`](docs/LIMITS.md)
- [`docs/WINDOWS.md`](docs/WINDOWS.md)
- [`docs/REMOTE.md`](docs/REMOTE.md)
- [`TESTING.md`](TESTING.md)
- [`SPEC-COMPLIANCE.md`](SPEC-COMPLIANCE.md)

## Completion (Spec §8–§11)
- `handlers/completion.sh` handles `completion/complete`, declining requests in minimal mode and limiting suggestions to the Spec §8 cap (≤100).
- `lib/completion.sh` aggregates completion suggestions and reports `hasMore`, ready to integrate with richer providers referenced in Spec §10 while piggybacking on pagination helpers for cursor semantics.

## Logging (Spec §13)
- `handlers/logging.sh` enforces RFC-5424 log levels via `logging/setLevel` and rejects invalid inputs with `-32602`, defaulting to `info` (overridable via `MCPBASH_LOG_LEVEL_DEFAULT`).
- `lib/logging.sh` tracks the active level and filters SDK-originated log notifications; worker subshells funnel JSON log entries through per-request streams that `lib/core.sh` emits after execution, keeping stdout protocol-safe.
# Trigger workflow update
