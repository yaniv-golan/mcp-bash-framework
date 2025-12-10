# Architecture & Implementation Details

## Why this architecture

mcp-bash follows one rule: do the minimum necessary to translate MCP messages into predictable script executions. No daemons, no servers, no hidden state. The surface area stays small so every part can be inspected and understood.

![MCP bash architecture diagram showing JSON-RPC between MCP client and core, core dispatch to user tools/resources/prompts, jq/gojq processing, and system command execution paths](../assets/architecture_diagram.png)
_Figure: High-level dataflow—MCP client sends JSON-RPC over stdio to mcp-bash core, which queries jq/gojq, dispatches into project tools/resources/prompts, and executes system commands._

## Repository layout
```
~/.local/share/mcp-bash/   # or mcp-bash-framework/ if cloned manually
├─ bin/mcp-bash
├─ lib/
│  ├─ auth.sh
│  ├─ core.sh
│  ├─ completion.sh
│  ├─ elicitation.sh
│  ├─ hash.sh
│  ├─ json.sh
│  ├─ lock.sh
│  ├─ ids.sh
│  ├─ io.sh
│  ├─ paginate.sh
│  ├─ path.sh
│  ├─ policy.sh
│  ├─ progress.sh
│  ├─ logging.sh
│  ├─ runtime.sh
│  ├─ registry.sh
│  ├─ resource_content.sh
│  ├─ resource_providers.sh
│  ├─ resources.sh
│  ├─ roots.sh
│  ├─ rpc.sh
│  ├─ prompts.sh
│  ├─ tools.sh
│  ├─ tools_policy.sh
│  ├─ timeout.sh
│  ├─ uri.sh
│  ├─ validate.sh
│  ├─ spec.sh
│  └─ cli/
├─ handlers/
│  ├─ completion.sh
│  ├─ lifecycle.sh
│  ├─ ping.sh
│  ├─ logging.sh
│  ├─ roots.sh
│  ├─ tools.sh
│  ├─ resources.sh
│  └─ prompts.sh
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
- Arrays are accepted when the negotiated protocol is `2025-03-26`; newer protocols reject batch arrays unless `MCPBASH_COMPAT_BATCHES=true`, in which case batches are decomposed into individual requests.
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
- `lib/tools.sh` scans the `tools/` tree (skipping dotfiles), prefers `NAME.meta.json` over inline `# mcp:` annotations, writes `.registry/tools.json`, and computes hash/timestamp data for pagination and list_changed notifications.
- Cursors are opaque base64url payloads with `ver`, `collection`, `offset`, `hash`, and `timestamp`; `tools/list` returns deterministic slices with `nextCursor` and `total`.
- `tools/call` wires the SDK env, captures stdout/stderr, surfaces `_meta.stderr`, emits structured content when metadata declares `outputSchema`, and returns `isError` on tool exit codes.
- Embedded resource content: tools can append to `MCP_TOOL_RESOURCES_FILE` (JSON array or tab-separated `path<TAB>mime<TAB>uri`) to have the framework emit `{type:"resource"}` entries in the result `content` array; binary files are base64 encoded automatically.
- Tool policy hook: if present, `server.d/policy.sh` defines `mcp_tools_policy_check()` and is invoked before every tool run (default implementation allows all tools).
- Executable `server.d/register.sh` can return a `tools` array to replace auto-discovery.

### Resources
- `handlers/resources.sh` supports `resources/list`, `resources/read`, `resources/subscribe`, and `resources/unsubscribe`, declining them in minimal mode.
- `lib/resources.sh` discovers entries under `resources/`, prefers metadata files, writes `.registry/resources.json`, and uses allow-listed providers with path normalization.
- Pagination mirrors tools via `lib/paginate.sh`, tracking registry hashes for list_changed notifications and returning `resources` plus `total` and optional `nextCursor`.
- `resources/read` resolves URIs through providers (default `providers/file.sh`), enforces roots allow lists, returns MIME hints and `_meta` diagnostics, and can subscribe; optional polling (`MCPBASH_RESOURCES_POLL_INTERVAL_SECS`, default `2`, set `0` to disable) pushes updates.
- File providers translate `C:\` prefixes into `/c/...` on Git-Bash/MSYS and honor `MSYS2_ARG_CONV_EXCL`. Git and HTTPS providers live in `providers/git.sh` and `providers/https.sh`.
- `server.d/register.sh` may emit `{ "tools": [...], "resources": [...], "prompts": [...] }` to bypass auto-discovery.

### Prompts
- `handlers/prompts.sh` implements `prompts/list` and `prompts/get`, rejecting both in minimal mode.
- `lib/prompts.sh` scans `prompts/`, writes `.registry/prompts.json`, paginates deterministically (returning `prompts`, `total`, and optional `nextCursor`), and renders templates with argument schemas into structured and text content.
- Manual overrides: `server.d/register.sh` can return a `prompts` array.

### Roots
- `handlers/roots.sh` handles `notifications/roots/list_changed` by re-requesting roots (debounced).
- `lib/roots.sh` tracks client support, sends `roots/list` after `initialized`, normalizes/percent-decodes `file://` URIs, drops stale responses via generations, and falls back to env/config on errors/timeouts.
- Tools block on `mcp_roots_wait_ready`; when ready, env includes `MCP_ROOTS_JSON`, `MCP_ROOTS_PATHS`, `MCP_ROOTS_COUNT`. SDK helpers expose `mcp_roots_list`, `mcp_roots_count`, and `mcp_roots_contains`.
- RPC callbacks in `lib/rpc.sh` route responses to roots without touching existing file-based pending responses.

### Progress & logs
- Workers buffer progress and log notifications and flush after handler completion by default.
- Set `MCPBASH_ENABLE_LIVE_PROGRESS=true` to stream notifications mid-flight; adjust cadence with `MCPBASH_PROGRESS_FLUSH_INTERVAL` (seconds).

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
