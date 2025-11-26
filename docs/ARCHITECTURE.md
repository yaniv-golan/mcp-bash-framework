# Architecture & Implementation Details

## Why this architecture

mcp-bash follows one rule: do the minimum necessary to translate MCP messages into predictable script executions. No daemons, no servers, no hidden state. The surface area stays small so every part can be inspected and understood.

## Repository layout
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
│  ├─ runtime.sh
│  ├─ completion.sh
│  ├─ resource_providers.sh
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
├─ sdk/
├─ server.d/
│  ├─ env.sh
│  └─ register.sh
├─ scaffold/
├─ examples/
├─ docs/
├─ test/
└─ .registry/ (generated caches, typically gitignored in projects)
```
Stable modules live under `bin/` and `lib/`, protocol handlers under `handlers/`, and dev assets under `scaffold/` and `examples/`. Project extensions (tools/resources/prompts) live in your project tree; registries are written to `.registry/`.

## Lifecycle loop
- `bin/mcp-bash` sources runtime, JSON, RPC, and core libraries, confirms stdout is a pipe or terminal, and enters `mcp_core_run`.
- Each line from stdio is BOM-stripped, trimmed, and compacted with jq/gojq or validated through the minimal tokenizer before dispatch.
- Arrays are rejected unless `MCPBASH_COMPAT_BATCHES=true`, in which case batches are decomposed into individual requests.
- Dispatch routes lifecycle, ping, logging, tools, resources, prompts, and completion methods; unknown methods return `-32601` and notifications remain server-owned.
- Responses flow through `rpc_send_line` to guarantee single-line JSON with newline termination and carriage-return scrubbing.

## Worker model
- The main loop handles lifecycle/ping/logging synchronously; async methods (`tools/*`, `resources/*`, `prompts/get`, `completion/complete`) spawn workers with per-request state under `${TMPDIR}/mcpbash.state.<ppid>.<bashpid>.<seed>`.
- Workers run in isolated subshells with request-scoped env and use `lib/ids.sh` to encode ids, track `pid.*` and `cancelled.*` markers, and clean up after completion.
- `lib/lock.sh`/`lib/io.sh` enforce mkdir-based stdout locks under `${TMPDIR}/mcpbash.locks`, strip CR, and validate UTF-8 so each response emits exactly one JSON line.
- Cancellation writes `notifications/cancelled`, marks ids, and escalates TERM → KILL on the worker process group; cancellation checks happen while holding the stdout lock.
- Minimal mode activates when JSON tooling is unavailable; tools/resources/prompts/completion decline requests while lifecycle/ping/logging stay available.

## Timeouts and cleanup
- `with_timeout <seconds> -- <command…>` (from `lib/timeout.sh`) runs a watchdog that sends TERM then KILL if a worker outlives the timeout.
- Async paths honor `params.timeoutSecs` when jq/gojq is present and wrap tool/resource/prompt/completion handlers with `with_timeout`; minimal mode skips per-request overrides.
- `bin/mcp-bash` traps `EXIT INT TERM` to run `mcp_runtime_cleanup`, removing `${TMPDIR}/mcpbash.state.*` and `${TMPDIR}/mcpbash.locks`.

## Handler notes

### Lifecycle and ping
- `handlers/lifecycle.sh` validates `initialize`, negotiates capabilities, waits for `notifications/initialized` before non-lifecycle traffic, and manages `shutdown`/`exit`.
- `handlers/ping.sh` returns immediate `{ "result": {} }` responses as a connectivity check.
- Core dispatch blocks non-lifecycle methods until initialization and emits explicit errors when uninitialized or shutting down.

### Tools
- `handlers/tools.sh` implements `tools/list` and `tools/call` and rejects both in minimal mode.
- `lib/tools.sh` scans the `tools/` tree (skipping dotfiles), prefers `NAME.meta.json` over inline `# mcp:` annotations, writes `registry/tools.json`, and computes hash/timestamp data for pagination and listChanged.
- Cursors are opaque base64url payloads with `ver`, `collection`, `offset`, `hash`, and `timestamp`; `tools/list` returns deterministic slices with `nextCursor` and `total`.
- `tools/call` wires the SDK env, captures stdout/stderr, surfaces `_meta.stderr`, emits structured content when metadata declares `outputSchema`, and returns `isError` on tool exit codes.
- Executable `server.d/register.sh` can return a `tools` array to replace auto-discovery.

### Resources
- `handlers/resources.sh` supports `resources/list`, `resources/read`, `resources/subscribe`, and `resources/unsubscribe`, declining them in minimal mode.
- `lib/resources.sh` discovers entries under `resources/`, prefers metadata files, writes `registry/resources.json`, and uses allow-listed providers with path normalization.
- Pagination mirrors tools via `lib/paginate.sh`, tracking registry hashes for listChanged notifications.
- `resources/read` resolves URIs through providers (default `providers/file.sh`), enforces roots allow lists, returns MIME hints and `_meta` diagnostics, and can subscribe; optional polling (`MCPBASH_RESOURCES_POLL_INTERVAL_SECS`, default `2`, set `0` to disable) pushes updates.
- File providers translate `C:\` prefixes into `/c/...` on Git-Bash/MSYS and honor `MSYS2_ARG_CONV_EXCL`. Git and HTTPS providers live in `providers/git.sh` and `providers/https.sh`.
- `server.d/register.sh` may emit `{ "tools": [...], "resources": [...], "prompts": [...] }` to bypass auto-discovery.

### Prompts
- `handlers/prompts.sh` implements `prompts/list` and `prompts/get`, rejecting both in minimal mode.
- `lib/prompts.sh` scans `prompts/`, writes `registry/prompts.json`, paginates deterministically, and renders templates with argument schemas into structured and text content.
- Manual overrides: `server.d/register.sh` can return a `prompts` array.

### Completion
- `handlers/completion.sh` serves `completion/complete`, declines in minimal mode, and caps suggestions at 100.
- `lib/completion.sh` aggregates suggestions, reports `hasMore`, and reuses pagination helpers for cursor semantics.

### Logging
- `handlers/logging.sh` enforces RFC-5424 levels via `logging/setLevel`, rejects invalid inputs with `-32602`, and defaults to `MCPBASH_LOG_LEVEL` (or `MCPBASH_LOG_LEVEL_DEFAULT` then `info`).
- `lib/logging.sh` tracks the active level and filters SDK log notifications; worker subshells stream JSON logs per request and `lib/core.sh` emits them after execution to keep stdout protocol-safe.

## What this architecture avoids
- No background daemons or hidden servers
- No long-lived mutable state beyond `.registry`
- No hidden watchers or background threads
- No magic: every dispatch path lives in `bin/`, `lib/`, or `handlers/` and is inspectable
