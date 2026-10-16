# Architecture & Implementation Details

## Why this architecture

mcp-bash follows one rule: do the minimum necessary to translate MCP messages into predictable script executions. No daemons, no servers, no hidden state. The surface area stays small so every part can be inspected and understood.

![MCP bash architecture diagram showing JSON-RPC between MCP client and core, core dispatch to user tools/resources/prompts, jq/gojq processing, and system command execution paths](../assets/architecture_diagram.png)
_Figure: High-level dataflow—MCP client sends JSON-RPC over stdio to mcp-bash core, which queries jq/gojq, dispatches into project tools/resources/prompts, and executes system commands._

## Repository layout

The framework (an install such as `~/.local/share/mcp-bash`, a clone, or a vendored `.mcp-bash/`):
```
mcp-bash/
├─ bin/mcp-bash      # CLI entry point and server launcher
├─ lib/              # runtime: read loop and workers (core.sh), JSON, registries,
│                    # resources/templates, policy, locking, logging, MCP Apps (ui*.sh)
│  └─ cli/           # CLI subcommands (validate, migrate, bundle, ...)
├─ handlers/         # one file per MCP method family (lifecycle, tools, resources, ...)
├─ providers/        # built-in resource providers: file, https, git, ui, echo
├─ sdk/              # helpers sourced by tool scripts (tool-sdk.sh, ui-sdk.sh)
└─ scaffold/         # templates for `mcp-bash new` / `scaffold`
```
A clone also has `examples/`, `docs/` and `test/`; installs don't need them. The files in `lib/` and `handlers/` are the reference; this page describes their roles rather than listing each one.

Your project (`MCPBASH_PROJECT_ROOT`):
```
my-server/
├─ tools/            # one directory per tool: tool.sh + tool.meta.json
├─ resources/        # static resources (*.meta.json + content) and templates
├─ prompts/
├─ completions/      # optional completion scripts
├─ providers/        # optional project resource providers (<scheme>.sh)
├─ server.d/         # optional project config and hooks
│  ├─ server.meta.json   # identity, optional "env" policy
│  ├─ register.json      # preferred: data-only registration (no shell execution)
│  ├─ register.sh        # hook registration (opt-in; executes shell code)
│  ├─ policy.sh          # optional: tool allow/deny hook
│  └─ env.sh             # env for run-tool --with-server-env (not sourced by the server)
└─ .registry/        # generated caches (typically gitignored)
```

## Lifecycle loop
- `bin/mcp-bash` sources runtime, JSON, RPC, and core libraries, confirms stdout is a pipe or terminal, and enters `mcp_core_run`.
- Each line from stdio is BOM-stripped, trimmed, and compacted with jq/gojq or validated through the minimal tokenizer before dispatch.
- Arrays are accepted when the negotiated protocol is `2025-03-26`; newer protocols reject batch arrays (the 1.x `MCPBASH_COMPAT_BATCHES` override is gone in 2.0). For 2025-03-26, batches are decomposed into individual requests. Batches under `2025-03-26` are answered one response per item: each response is its own line, not one JSON array, and responses from long-running requests may arrive after later items. <!-- lint-api-usage: allow -->
- Dispatch routes lifecycle, ping, logging, tools, resources, prompts, and completion methods; unknown methods return `-32601` and notifications remain server-owned.
- Responses flow through `rpc_send_line` to guarantee single-line JSON with newline termination and carriage-return scrubbing.

## Worker model
- The main loop handles lifecycle/ping/logging synchronously; async methods (`tools/*`, `resources/*`, `prompts/get`, `completion/complete`) spawn workers with per-request state under a private `mktemp -d` directory, `${TMPDIR}/mcpbash.state.<ppid>.<bashpid>.XXXXXX`.
- Workers run in isolated subshells with request-scoped env and use `lib/ids.sh` to encode ids, track `pid.*` and `cancelled.*` markers, and clean up after completion.
- `lib/lock.sh`/`lib/io.sh` enforce mkdir-based stdout locks under the instance lock root (`<state dir>/locks` unless `MCPBASH_LOCK_ROOT` is set), strip CR, and validate UTF-8 so each response emits exactly one JSON line.
- Cancellation writes `notifications/cancelled`, marks ids, and escalates TERM → KILL on the worker process group; cancellation checks happen while holding the stdout lock.
- Minimal mode activates when JSON tooling is unavailable; tools/resources/prompts/completion decline requests while lifecycle/ping/logging stay available.

## Timeouts and cleanup
- `with_timeout <seconds> -- <command…>` (from `lib/timeout.sh`) runs a watchdog that sends TERM then KILL if a worker outlives the timeout.
- Async paths honor `params.timeoutSecs` when jq/gojq is present and wrap tool/resource/prompt/completion handlers with `with_timeout`; minimal mode skips per-request overrides. Defaults apply without it: `tools/*` 30s, `resources/read` and `resources/subscribe` 120s. A handler killed by its timeout is answered with `-32603` (`<method> timed out after Ns`), unless it had already responded.
- `bin/mcp-bash` traps `EXIT INT TERM` to run `mcp_runtime_cleanup`. On an abnormal exit the handler first stops running workers (TERM, then KILL after 1s). Cleanup removes only the state dir and lock root the server created (never through a symlink); directories the operator set are left alone. CLI commands remove their private state dir on exit.

## Handler notes

### Lifecycle and ping
- `handlers/lifecycle.sh` validates `initialize`, negotiates capabilities, waits for `notifications/initialized` before non-lifecycle traffic, and manages `shutdown`/`exit`.
- `handlers/ping.sh` returns immediate `{ "result": {} }` responses as a connectivity check.
- Core dispatch blocks non-lifecycle methods until initialization and emits explicit errors when uninitialized or shutting down.

### Tools
- `handlers/tools.sh` implements `tools/list` and `tools/call` and rejects both in minimal mode.
- `lib/tools.sh` scans the `tools/` tree (skipping dotfiles), prefers `NAME.meta.json` over inline `# mcp:` annotations, writes `.registry/tools.json`, and computes hash/timestamp data for pagination and list_changed notifications.
- Cursors are opaque base64url payloads with `ver`, `collection`, `offset`, `hash`, and `timestamp`; `tools/list` returns deterministic slices with `nextCursor` and exposes the full count as an extension via `result._meta["mcpbash/total"]` (not a top-level field) for strict-client compatibility.
- `tools/call` wires the SDK env, captures stdout/stderr, surfaces `_meta.stderr`, emits structured content when metadata declares `outputSchema`, and returns `isError` on tool exit codes.
- Embedded resource content: tools can append to `MCP_TOOL_RESOURCES_FILE` (JSON array or tab-separated `path<TAB>mime<TAB>uri`) to have the framework emit `{type:"resource"}` entries in the result `content` array; binary files are base64 encoded automatically.
- Tool policy: before every tool run the built-in policy (deny-by-default `MCPBASH_TOOL_ALLOWLIST`, tool path checks) runs, then `mcp_tools_policy_project()` if `server.d/policy.sh` defines it; the project hook can only deny. A `policy.sh` that still defines the 1.x `mcp_tools_policy_check()` gets every call refused. <!-- lint-api-usage: allow -->
- Declarative registration: `server.d/register.json` can provide a `tools` array (and other kinds) without executing project shell code; if present, it takes precedence and invalid input fails loudly (no fallback to hooks).
- Hook registration: `server.d/register.sh` can return a `tools` array to replace auto-discovery, but it executes shell code and is opt-in (`MCPBASH_ALLOW_PROJECT_HOOKS=true` plus safe ownership/permissions).

### Resources
- `handlers/resources.sh` supports `resources/list`, `resources/read`, `resources/subscribe`, and `resources/unsubscribe`, declining them in minimal mode.
- `lib/resources.sh` discovers entries under `resources/`, prefers metadata files, writes `.registry/resources.json`, and uses allow-listed providers with path normalization.
- Pagination mirrors tools via `lib/paginate.sh`, tracking registry hashes for list_changed notifications and returning `resources`, optional `nextCursor`, and an extension count via `result._meta["mcpbash/total"]`.
- `resources/read` resolves URIs through providers (default `providers/file.sh`), enforces roots allow lists, returns MIME hints and `_meta` diagnostics, and can subscribe; subscription polling (`MCPBASH_RESOURCES_POLL_INTERVAL_SECS`, default `2`, set `0` to disable) starts on first `resources/subscribe` and pushes updates.
- File providers translate `C:\` prefixes into `/c/...` on Git-Bash/MSYS and honor `MSYS2_ARG_CONV_EXCL`. Git and HTTPS providers live in `providers/git.sh` and `providers/https.sh`.
- `server.d/register.json` can supply `resources` / `resourceTemplates` for data-only overrides; `server.d/register.sh` may emit `{ "tools": [...], "resources": [...], "resourceTemplates": [...], "prompts": [...], "completions": [...] }` for hook-based overrides (opt-in).

### Prompts
- `handlers/prompts.sh` implements `prompts/list` and `prompts/get`, rejecting both in minimal mode.
- `lib/prompts.sh` scans `prompts/`, writes `.registry/prompts.json`, paginates deterministically (returning `prompts`, optional `nextCursor`, and an extension count via `result._meta["mcpbash/total"]`), and renders templates with argument schemas into structured and text content.
- Manual overrides: `server.d/register.json` or `server.d/register.sh` can provide a `prompts` array; prefer `register.json` unless you need dynamic behavior.

### Roots
- `handlers/roots.sh` handles `notifications/roots/list_changed` by re-requesting roots (debounced).
- `lib/roots.sh` tracks client support, sends `roots/list` after `initialized`, normalizes/percent-decodes `file://` URIs, drops stale responses via generations, and falls back to env/config on errors/timeouts.
- Tools block on `mcp_roots_wait_ready`; when ready, env includes `MCP_ROOTS_JSON`, `MCP_ROOTS_PATHS`, `MCP_ROOTS_COUNT`. SDK helpers expose `mcp_roots_list`, `mcp_roots_count`, and `mcp_roots_contains`.
- RPC callbacks in `lib/rpc.sh` route responses to roots without touching existing file-based pending responses.

### Progress & logs
- Workers buffer progress and log notifications and flush after handler completion by default.
- Set `MCPBASH_ENABLE_LIVE_PROGRESS=true` to stream notifications mid-flight (starts a background flusher); adjust cadence with `MCPBASH_PROGRESS_FLUSH_INTERVAL` (seconds).

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

## Modern requests (MCP 2026-07-28)

With `MCPBASH_MODERN_PROTOCOL=true` (off by default), the server also serves MCP 2026-07-28, the stateless revision, in the same process as the legacy `initialize` session.

- **Era per request.** A request whose `params._meta` has `io.modelcontextprotocol/protocolVersion` is modern (`lib/modern.sh`). It needs no `initialize`, and the protocol version and client capabilities come from that request's `_meta` only.
- **Checks.** A version other than `2026-07-28` gets `-32022` with `data.supported` (every version the server speaks) and `data.requested`; missing `io.modelcontextprotocol/clientCapabilities`, or an invalid `logLevel`, gets `-32602`. Methods 2026-07-28 removed (`ping`, `logging/setLevel`, `resources/subscribe`/`unsubscribe`, `initialize`, `shutdown`, roots notifications) get `-32601 "Method not found"`.
- **Isolation.** `server/discover` is answered at once from static data (no registry scan). Every other modern request runs in a worker, never in the main process, which holds the legacy session's state; the worker replaces the client-capability globals with the request's own and exports `MCPBASH_PROTOCOL_ERA=modern` (so `mcp_result_json` may send any JSON value as `structuredContent`).
- **No server requests.** stdio forbids server-to-client requests in 2026-07-28. A tool's question ends the call with an `input_required` result instead (`lib/mrtr.sh`): the call gets a journal in the state dir, named by a random 128-bit ticket that is the `requestState`; the SDK records `mcp_once` steps and the question there and blocks, the tool's timeout watchdog stops it within a second, and the worker answers `input_required`. The client's retry is checked (ticket, expiry, tool and arguments digest), its `inputResponses` go into the journal, and the tool runs again, replaying what it recorded. Only a request whose capabilities include `elicitation` gets a journal. Roots come from `MCPBASH_ROOTS`, `config/roots.json` or the project root.
- **Results.** Every result gets `resultType: "complete"` and `_meta["io.modelcontextprotocol/serverInfo"]`; `server/discover`, the four list results and `resources/read` get `ttlMs` and `cacheScope`. Resource not found is `-32602` (not `-32002`), and legacy server codes (`-32000`..`-32019`) become `-32603`.
- **Notifications.** A modern request gets log notifications only when it carries `_meta["io.modelcontextprotocol/logLevel"]`, at that level; progress follows `progressToken` as before. They go out before the request's result (progress must stop once a request completes), so they count against the request's timeout: a request that times out while they are being sent gets the timeout error. Legacy requests still send buffered notifications after the result. `server/discover` advertises no `listChanged` or `subscribe` (on 2026-07-28 they mean `subscriptions/listen`, not served yet), and unsolicited notifications go only to a legacy session.

