# MCP-Bash Technical Specification

## 1. Scope and Goals
- Deliver a Bash-only Model Context Protocol (MCP) server framework that runs unmodified on macOS (Bash 3.2) and Linux distributions with Bash ≥3.2, and experimentally on Windows environments that ship Git-Bash/MSYS/WSL (with documented limitations).
- Provide a stable, versioned core (`bin/`, `lib/`, `handlers/`, `providers/`, `sdk/`) that server authors do not edit, paired with drop-in extension directories (`tools/`, `resources/`, `prompts/`, `server.d/`) to define application-specific behavior.
- Adhere to the MCP basic transport, lifecycle, capabilities, and server feature specifications current as of March–June 2025, explicitly targeting protocol version `2025-06-18` while degrading only when a client negotiates an older version.
- Guarantee strict stdout discipline (one JSON object per line) and resilient concurrency without relying on non-portable Unix features.
- This document defines the complete deliverables for a GitHub-ready project: repository layout, source code, documentation set, examples, CI workflows, and testing requirements. Implementation MUST produce the full tree and assets described herein; treat this spec as the single source of truth.
- Supported transport is **stdio only**. Streamable HTTP / SSE / OAuth-backed deployments are explicitly out of scope for `mcp-bash`; clients requiring remote transports must use an alternative server implementation.

## 2. Target Runtime Environment
- **Shell**: POSIX-compatible Bash 3.2 grammar; no associative arrays, no process substitution, no `wait -n`, no Bash 4+ features.
- **Utilities**: JSON tooling detection order is `gojq` → `jq`. When either `gojq` or `jq` is present, the server delivers the full MCP protocol surface, compacting JSON with `-c`. If neither binary exists, the core enters a **minimal mode** that only implements lifecycle, ping, and logging via the restricted tokenizer described below, loudly warns about unsupported methods, and advertises reduced capabilities. Other dependencies are ubiquitous POSIX tools (`mkdir`, `kill`, `sleep`, `base64`, `tr`).
- **Filesystem**: Writable temp directory via `$TMPDIR` (macOS), `/tmp` (Linux, WSL), or MSYS equivalents. No special filesystems or sockets required.
- **Encoding**: UTF-8 end-to-end; stdio framing expects newline-delimited single-line JSON messages.

**Minimal mode surface (no JSON tooling available)**

| Feature                    | Full Mode (`gojq`/`jq`)        | Minimal Mode |
|----------------------------|-------------------------------|--------------|
| `initialize`/lifecycle     | ✔️                            | ✔️           |
| `ping`                     | ✔️                            | ✔️           |
| `logging/setLevel`         | ✔️                            | ✔️           |
| `tools/list` & pagination  | ✔️                            | ✖️ (returns `-32601`) |
| `tools/call`               | ✔️                            | ✖️           |
| Structured output          | ✔️                            | ✖️           |
| `resources/*` methods      | ✔️                            | ✖️           |
| `prompts/*`                | ✔️                            | ✖️           |
| `completion/complete`      | ✔️                            | ✖️           |
| Progress notifications     | ✔️                            | Limited (no JSON marshalling) |
| Subscriptions              | ✔️                            | ✖️           |

Operators can explicitly opt into minimal mode even when tooling is present for diagnostics and footprint comparisons.
Minimal mode relies on a strict, built-in JSON tokenizer that only accepts single JSON objects and extracts top-level `"id"` (string/number) and `"method"` (string). Any other structure—including arrays, nested objects for `"params"` beyond raw passthrough, `"id":null`, or invalid JSON—produces `-32600 Invalid Request`. SDK helpers that require jq (e.g., `mcp_args_get`) are disabled in minimal mode; tools must parse `mcp_args_raw` manually when operating in this tier.

**Legacy batch compatibility**  
Set `MCPBASH_COMPAT_BATCHES=true` to accept pre-2025-03-26 JSON-RPC batch arrays. In this mode, each element of the incoming array is dispatched as an independent request and responses remain single-line objects (never batched). This flag is disabled by default and should be used only when interfacing with legacy clients.

## 3. Repository Layout Contract
```
mcp-bash/
├─ bin/mcp-bash                # entrypoint, sources core and dispatches main loop
├─ lib/                        # stable shell modules (never edited downstream)
│  ├─ core.sh                  # process bootstrap, init handshake, dispatcher
│  ├─ rpc.sh                   # JSON-RPC helpers for send/receive
│  ├─ json.sh                  # jq detection, JSON escaping/compacting
│  ├─ lock.sh                  # portable lock-dir primitives
│  ├─ timeout.sh               # subshell timeout orchestration
│  ├─ io.sh                    # stdout/stderr discipline
│  ├─ ids.sh                   # request id⇔pid registry, cancellation markers
│  ├─ paginate.sh              # opaque cursor encode/decode
│  ├─ progress.sh              # progress notification helpers
│  ├─ logging.sh               # logging capability helpers
│  └─ spec.sh                  # capability negotiation helpers
├─ handlers/                   # protocol method handlers (do not edit)
│  ├─ lifecycle.sh             # initialize/initialized/shutdown, cancellation hook
│  ├─ ping.sh                  # ping
│  ├─ logging.sh               # logging/setLevel and message notifications
│  ├─ tools.sh                 # tools/list, tools/call orchestration
│  ├─ resources.sh             # resources list/read/templates/subscribe
│  ├─ prompts.sh               # prompts list/get pipeline
│  └─ completion.sh            # completion/complete router
├─ providers/                  # stock providers (e.g., file scheme implementation)
├─ sdk/tool-sdk.sh             # optional helper API for tool scripts
├─ server.d/                   # optional server-specific hooks
│  ├─ env.sh                   # env defaults (roots, log level, etc.)
│  └─ register.sh              # manual registration overrides
├─ registry/                   # runtime-generated indexes (ignored by VCS)
├─ tools/, resources/, prompts/ # drop-in extension directories
├─ test/                       # smoke tests + fixtures
└─ docs/                       # documentation set (including this spec)
```

## 4. Lifecycle and JSON-RPC Flow
1. **Bootstrap**: `bin/mcp-bash` sources `lib/core.sh`, initializes environment (`set -euo pipefail`), confirms stdout is a terminal or pipe, and starts the primary read loop.
2. **Receiving**: Each inbound line MUST be a single JSON object (batched arrays were removed in MCP 2025-06-18). The reader strips any UTF-8 BOM, trims leading/trailing whitespace (including `\r` from CRLF endings), rejects any message framed as an array (first non-whitespace character `[`) with `-32600 Invalid Request`, and only accepts objects (`{ ... }`). An optional compatibility mode (disabled by default, logs a warning on use) can be toggled to tolerate legacy batches when interacting with pre-2025-03-26 clients; even in that mode, responses remain one-per-line objects. Messages are compacted with `jq -c` to maintain the one-line contract.
3. **Dispatch**: `lib/core.sh` delegates to handler functions keyed by `method`. Lifecycle methods execute in the main shell; user-invoked operations spawn background subshells.
4. **Responses**: Worker subshells produce full JSON strings and pass them through `rpc_send_line`, which serializes writes using the lock-dir to guarantee atomic line emission.
5. **Parser Assurance**: When `gojq`, `jq`, or Python’s `json` module is available, the server maintains complete JSON fidelity and aborts initialization if compacting/parsing fails. If none of these tools exist, the core logs a prominent warning, downgrades capabilities to the minimal feature set (lifecycle, ping, logging), and relies on the restricted tokenizer described in §2 to extract top-level `method`/`id`; any other request shape receives `-32600` without attempting generic JSON parsing.

## 5. Concurrency Model
- Each request that may block or perform user work (`tools/*`, `resources/*`, `prompts/get`, `completion/complete`) executes inside `(&)` to avoid head-of-line blocking.
- `lib/ids.sh` maintains `state/pid.<requestId>` and `state/cancelled.<requestId>` files (under `${TMPDIR}/mcpbash.state.${PPID}.${BASHPID}.${STATE_SEED}`) to track workers and support cancellation. `STATE_SEED` is initialized once during bootstrap from `$RANDOM` to avoid collisions. Raw JSON-RPC ids are base64url-encoded before becoming filenames so both numeric and string identifiers are handled safely (implemented via `base64 -w0` on GNU systems or `base64 | tr -d '\n'` on BSD/macOS, followed by `tr '+/' '-_'` and `tr -d '='`); newline stripping is mandatory. If the encoded id exceeds 200 characters, the server uses a stable SHA-256 digest to keep filenames within POSIX limits. State files are cleaned when workers exit.
- Outbound messages (responses, progress, logging) acquire `stdout` lock before touching `stdout` to prevent interleaving.
- Workers perform a final cancellation check **while holding** the stdout lock so the “check → emit” sequence is atomic and cannot race with late-arriving `notifications/cancelled`.
- Each worker (and optional watchdog) runs in its own process group (`setsid` when available, or `set -m; kill -- -$pgid` fallback) so cancellation escalations (`TERM` → `KILL`) reach grandchildren portably across macOS, Linux, and MSYS.
- Immediately before emission the framework strips any residual `\r` from tool output, enforces UTF-8 validation, and appends a single `\n`—never allowing CRLF or BOM sequences onto stdout.
- Tool stderr streams are redirected to `${STATE_DIR}/stderr.<requestId>.log`; on completion the framework reads the entire file (subject to future configurable truncation) and embeds it in `_meta.stderr` for error responses before releasing the stdout lock.
- Cancellation path (`notifications/cancelled`) marks the request as cancelled, sends `TERM`, waits a grace interval, and escalates to `KILL` if the worker still runs. Any result emitted after cancellation is discarded by checking the cancellation marker prior to serialization.

## 6. Timeouts and Long-Running Operations
- `with_timeout <seconds> -- <command...>` forks both the worker and a watchdog. The watchdog issues `TERM`, waits one second, then `KILL`s if necessary. Cleanup ensures the watchdog terminates when the worker exits early.
- Handlers may wrap user code with `with_timeout` (accepting integer seconds) based on metadata (e.g., optional `timeoutSecs` from tool metadata) to prevent runaway processes.
- `bin/mcp-bash` installs a `trap` on `EXIT` (and TERM/INT) to remove the randomized state (`$TMPDIR/mcpbash.state.$PPID.$BASHPID.$STATE_SEED`) and lock directories so stale state does not persist after normal shutdowns.

## 7. Capability Negotiation
During `initialize`, the server responds with:
```json
{
  "protocolVersion": "2025-06-18",
  "capabilities": {
    "logging": {},
    "tools": { "listChanged": true },
    "resources": { "subscribe": true, "listChanged": true },
    "prompts": { "listChanged": true },
    "completion": {}
  },
  "serverInfo": { "name": "mcp-bash", "version": "0.1.0", "title": "MCP Bash Server" }
}
```
- Capability map can be reduced if the client requests an earlier protocol revision or if neither `gojq` nor `jq` is available (in which case only lifecycle/logging capabilities are exposed).
- `lib/spec.sh` stores capability templates and allows future negotiation tweaks (e.g., protocol downgrades).
- Post-`initialized` notification, the server begins emitting background notifications such as `notifications/message` and `notifications/*/list_changed`.
- The `protocolVersion` returned here is authoritative for the session; subsequent messages adhere strictly to that revision’s semantics.
- Cancellation targeting the in-flight `initialize` request is ignored as an implementation choice (cancellation delivery is best-effort); the server finishes initialization before honoring `notifications/cancelled` for subsequent requests.
- On `shutdown`, the server responds immediately, stops accepting new requests, and waits up to five seconds for the client to send `exit`. If `exit` arrives within the window, the server terminates with exit code 0; otherwise it self-terminates after the timeout with exit code 0.
- Client compatibility note: GitHub Copilot’s coding agent, when MCP access is enabled via enterprise policy, can consume tools, resources, and prompts—ensure all capabilities remain functional even if certain clients primarily exercise tools.

## 8. Handler Responsibilities
| Handler | Responsibilities | Notes |
|---------|------------------|-------|
| `lifecycle.sh` | Validate protocol version, advertise capabilities, route `shutdown`, handle `notifications/initialized`, and process cancellation notifications. | Ensures no non-lifecycle traffic is emitted before client sends `initialized`. |
| `ping.sh` | Immediate `{ "result": {} }` response. | Always available to confirm connectivity. |
| `logging.sh` | Update log level thresholds, emit structured log notifications. | Uses syslog severity names (`debug`–`fatal`). |
| `tools.sh` | Auto-discover tools, paginate `tools/list`, invoke executables in subshells for `tools/call`. | Drafts `registry/tools.json` on boot for fast pagination; suppresses structured output when only minimal mode (no JSON tooling) is available. |
| `resources.sh` | Aggregate templates, list resources, run readers, and handle subscriptions via `resources/subscribe` / `resources/unsubscribe` (server extension aligned with draft spec). | Includes stock `providers/file.sh` for filesystem URIs guarded by roots allow-list; emits `notifications/resources/updated` while subscribed and stops after `resources/unsubscribe` or disconnect. |
| `prompts.sh` | Index prompt templates, render templates with argument substitution, trigger list change notifications. | Supports YAML metadata per prompt, optional shell assembly. |
| `completion.sh` | Route completion requests to prompt/resource-specific scripts, enforce max 100 results, and return `hasMore` when truncated. | Utilizes cursor metadata for follow-up requests. |

## 9. Auto-Discovery Pipeline
1. **Boot Scan**: `handlers/tools.sh` walks `tools/` for executables. Metadata precedence: `NAME.meta.yaml` → `# mcp:` inline annotations → default schema (no arguments).
2. **Registry Generation**: Results cached under `registry/tools.json` / `resources.json` / `prompts.json` with pagination metadata (offset, page size); documentation will include sample JSON stubs (see forthcoming `docs/REGISTRY.md`) so extension authors understand the schema.
3. **Reactive Notifications**: Directory timestamp changes (checked via `find` mtime hash) trigger `notifications/tools/list_changed`, etc., during idle cycles.
4. **Manual Overrides**: Presence of `server.d/register.sh` bypasses auto-discovery; the script must call registration helpers exported by `lib/core.sh`.
5. **Structured Output Policy**: Tool metadata may include `outputSchema` (JSON Schema Draft 7). When `gojq`/`jq`/Python is available, the server validates tool responses and emits both `structuredContent` (parsed JSON) **and** a `content[]` text fallback containing the same serialized data (treated as mandatory for client compatibility, per spec SHOULD). Validation currently performs lightweight type/required-field checks (not full Draft 7 compliance); deeper validation can be delegated to external validators via optional hooks. In minimal mode (no JSON tooling), `outputSchema` is ignored and structured content is suppressed with a warning.
6. **Notification TTL**: Registries carry an in-process TTL so that even if a client ignores `list_changed`, subsequent list requests always see the latest filesystem state.
7. **Discovery performance**: `find` scans skip hidden directories, limit depth to three levels, and reuse directory mtimes to keep scans sub-second for ~100 tools. Large trees trigger warnings and suggest manual registration.

## 10. Tool Runtime SDK
- `MCP_SDK` env var points to `sdk/`.
- `tool-sdk.sh` offers:
- `mcp_progress <pct> "<message>"` → emits `notifications/progress` when request carries `_meta.progressToken`.
    - Validates that progress tokens are strings or numbers (per MCP schema) before emitting notifications.
- `mcp_is_cancelled` → polls cancellation marker for cooperative termination.
- `mcp_log <level> <logger> <json>` → structured logs respecting log level.
- `mcp_args_get '<jq-filter>'` → convenience wrapper for reading arguments. It is available only when `gojq` or `jq` is present; otherwise the helper prints a warning to stderr, returns exit code `1`, and tool authors must use `mcp_args_raw` (raw JSON) together with their own parser (e.g., Python) inside the tool.
- `mcp_emit_text "<text>"` and `mcp_emit_json '<json>'` to build tool responses cleanly; `mcp_emit_json` validates against declared `outputSchema` and wires both `structuredContent` and text fallback automatically when a JSON processor is available, otherwise it degrades to text-only output in minimal mode.
- `mcp_log <level> <logger> <json>` enforces RFC-5424 syslog level names (`debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, `emergency`).
- SDK functions write to a pipe consumed by core `progress/logging` helpers, preserving serialization guarantees.
- Example fallback pattern when jq is absent:
  ```bash
  if ! result="$(mcp_args_get '.message' 2>/dev/null)"; then
    raw="$(mcp_args_raw)"
    result="$(printf '%s' "$raw" | jq -r '.message')"
  fi
  ```

## 11. Pagination Scheme
- `lib/paginate.sh` encodes cursor objects as opaque strings (current implementation uses JSON containing `{"ver":1,"collection":"tools","offset":...,"hash":"...","timestamp":...}` base64url-encoded with newline-free output as described in §5) without revealing structure to clients. Cursors whose `ver` value is not recognized (anything other than `1`) result in `-32602 Invalid Params` so the client can request a fresh cursor.
- List handlers accept optional `params.cursor` and `params.limit`; they respond with `nextCursor` when additional items remain.
- Server keeps registry snapshots sorted alphabetically to ensure deterministic pagination across invocations.

## 12. Portability Considerations
- **Locking**: Directory-based locks live under `$TMPDIR/mcpbash.locks`. Acquisition uses `mkdir`. If a lock directory exists, the locker PID is checked via `kill -0`; stale locks are removed before retrying.
- **Timeouts**: Implemented with background watchdogs instead of `timeout(1)` to stay portable on macOS and Windows.
- **Signal Semantics**: Git-Bash/MSYS support `kill` for Bash-spawned processes, enabling cancellation and timeouts to function. Windows console events are not relied upon.
- **Path Handling**: All framework code works with POSIX-style paths. Resource providers translate as needed (e.g., `providers/file.sh` can normalize Windows drive prefixes).
- **Windows Drive Translation**: Document Git-Bash/MSYS behavior that maps `C:\foo\bar` to `/c/foo/bar` (no colon) and reference MSYS2 path conversion docs. Configuration helpers canonicalize drive-prefixed paths to POSIX form to avoid “Is a directory” errors; authors can disable conversion per-argument via `MSYS2_ARG_CONV_EXCL`.
- **Windows Support Caveats**: Git-Bash/MSYS signal handling (especially `SIGTERM`) and PID probing may behave inconsistently across environments. Document Windows support as **experimental**, list known limitations (e.g., unreliable `kill -TERM`, UNC paths, backslash-relative paths), and recommend additional testing before deploying to production Windows hosts. For production Windows usage, prefer running the server under Windows Subsystem for Linux (WSL) and launching via `wsl bash /path/to/mcp-bash`.
- **State path length**: If `${TMPDIR}` produces overly long state/lock paths (approaching UNIX socket/path limits), the server hashes the base path to a shorter prefix (`mcps.<hash>`) and logs the adjustment; operators can override via `MCPBASH_STATE_DIR`.

## 13. Logging and Diagnostics
- Logging capability defaults to `info` level; configurable via `server.d/env.sh` or `logging/setLevel`.
- If the client never issues `logging/setLevel`, the server continues emitting `notifications/message` at the default level so Inspector/Claude/Copilot still receive diagnostics.
- Diagnostic output intended for humans goes to `stderr` only during bootstrap. After initialization, structured notifications replace stderr to maintain protocol purity.
- Optionally, a ring buffer of recent notifications may be kept for debugging (future enhancement).

## 14. Security Posture
- Tools and resource providers inherit the server’s environment. Operators are encouraged to set allow-lists (`MCP_ROOTS`) to constrain filesystem access.
- JSON escaping ensures no control characters leak into the stdio stream.
- Registry files are regenerated on boot; they should be excluded from version control (`.gitignore`) to avoid leaking runtime data.
- No network requests are performed by the core. External network activity is left to user-provided tools/resources.
- Input validation expectations: tool arguments are sanitized via JSON parsing (no shell interpolation), YAML metadata is parsed with strict safe-mode loaders, and path arguments are resolved within configured roots. Filters passed to `mcp_args_get` are subject to allow-listed operations to avoid shell injection.
- Operators SHOULD define per-request timeouts, memory limits, and environment variable allow/block lists via `server.d/env.sh` or wrapper scripts when deploying in shared environments.

## 15. Resource Limits & Performance Expectations
- **Concurrency ceilings**: default `MAX_CONCURRENT_REQUESTS=16`, configurable; additional requests queue until a worker is available.
- **Concurrency tuning**: increase to 32–64 for I/O-bound tools, reduce to 4–8 for memory-heavy workloads. Monitor concurrency with `ls "$STATE_DIR"/pid.* 2>/dev/null | wc -l` (the core exports `STATE_DIR` for this purpose).
- **Timeout defaults**: `DEFAULT_TOOL_TIMEOUT=30`, `DEFAULT_SUBSCRIBE_TIMEOUT=120` (seconds), overridable per tool/resource metadata.
- **Output guarding**: responses larger than `MAX_TOOL_OUTPUT_SIZE=10MB` are truncated with an error response; stdout flood protection uses `head -c` guards prior to emission.
- **Registry guardrails**: auto-discovery warns when `tools/`, `resources/`, or `prompts/` contains >500 entries and caps total registry cache size at 100MB.
- **Notification throttling**: progress/logging notifications are rate-limited to 100/minute per request (configurable via `MAX_PROGRESS_PER_MIN`, e.g., raise to 300 for high-frequency updates) using a sliding-window counter: each emission appends a Unix timestamp to `${STATE_DIR}/progress.<requestId>.log`, prunes entries older than 60 seconds, and proceeds only if the remaining count is ≤ limit. The log file is deleted when the worker exits.
- **Performance expectations**: framework dispatch overhead adds ~50–100ms per request; throughput is predominantly limited by tool execution but single-process Bash architecture is expected to sustain 10–20 concurrent requests comfortably on modern hardware.
- **Pagination cursors**: include registry hash and timestamp metadata so stale cursors can be rejected when discovery re-runs.

## 16. Failure Handling & Recovery
- **Tool lifecycle**: non-zero exit codes map to tool error responses; crashes or truncation log structured errors and surface `isError=true`.
- **Error payloads**: tool failures return `{"content":[{"type":"text","text":"Tool failed: <reason>"}],"isError":true,"_meta":{"exitCode":<code>,"stderr":"..."}}` so clients receive both human-readable and structured diagnostics.
- **Malformed output**: invalid JSON/UTF-8 from tools is detected pre-emission (UTF-8 validation via `iconv`, JSON parsing via `jq`/Python) and swapped with an error result plus diagnostic log entry.
- **Hanging tools**: watchdog escalates from `TERM` to `KILL`; failure to terminate results in process group cleanup and a logged incident.
- **Watchdog orphans**: watchdog processes include self-termination timers and are tracked in state; if the parent dies unexpectedly they exit once their timeout elapses, preventing orphan accumulation.
- **Stdout corruption**: if a response cannot be compacted to single-line JSON, the server logs a protocol error, drops the message, and increments a sliding-window counter. Three or more corruption events within 60 seconds trigger an immediate shutdown with exit code 2 unless `MCPBASH_ALLOW_CORRUPT_STDOUT=true` is set for debugging.
- **Metadata errors**: malformed tool/resource metadata causes the entry to be skipped with warnings, avoiding registry corruption.
- **State directories**: unique state/lock paths incorporate `$PPID`, `$BASHPID` (falling back to `$$` where unavailable), and a boot-time `STATE_SEED` derived from `$RANDOM` to minimize collisions across multiple instances and PID reuse.
- **Failure catalog**:
  | Failure Mode            | Detection Mechanism                  | Recovery Strategy                          |
  |-------------------------|--------------------------------------|--------------------------------------------|
  | Tool hang               | Timeout watchdog                     | SIGTERM → SIGKILL + error response         |
  | Tool crash              | Exit code ≠ 0                       | Structured error result, log               |
  | Invalid JSON output     | Parser failure                      | Error response + warning                   |
| Stdout corruption       | Non-JSON line                       | Log, drop message, auto-abort after 3 events/60s (`MCPBASH_ALLOW_CORRUPT_STDOUT=true` to override) |
  | Registry scan failure   | Discovery exit code                 | Retry with backoff, degrade to minimal mode|
  | Disk exhaustion         | Write failure                       | Log critical, refuse new requests          |
  | PID lookup failure      | `kill -0` error                     | Assume stale entry, clean state            |


## 17. Extension Author Workflow
1. Populate `tools/` with executable scripts plus optional metadata.
2. Add prompt templates under `prompts/` with matching `.meta.yaml` describing arguments.
3. Define resource templates and readers under `resources/`, optionally leveraging `providers/file.sh`.
4. Adjust defaults via `server.d/env.sh` (e.g., `PAGE_SIZE`, `LOG_LEVEL_DEFAULT`, `ROOTS`).
5. (Optional) Provide `server.d/register.sh` for complete manual control of registration.
6. Run `test/smoke.sh` to verify MCP handshake and tool execution across platforms (CI mirrors this).
7. Reference upcoming samples in `examples/` for canonical tool metadata (`*.meta.yaml`), SDK usage, and registry outputs when scaffolding new extensions.

## 18. Testing and CI Expectations
- `test/smoke.sh` issues a scripted initialize → tools list → tools call interaction against `bin/mcp-bash`.
- GitHub Actions matrix (`.github/workflows/ci.yml`) runs:
  - `shellcheck` on all `.sh` files.
  - `shfmt -d` for formatting enforcement (configured to Bash 3.2-compatible settings).
  - Smoke tests on macOS, Ubuntu, and Windows (GitHub-hosted runners with Git-Bash).
- Unit tests (shell-based) cover library helpers such as `lib/lock.sh`, `lib/paginate.sh`, and structured-output shaping functions, executing via `bats` or an equivalent harness.
- Integration tests spin up the full server using fixture tool/resource directories to exercise capability negotiation, structured content, pagination, cancellation, progress, Windows path normalization scenarios, and the Python fallback pipeline.
- CI smoke tests assert: every outbound message is a single-line JSON object, `tools/call` returns matching `structuredContent` and text fallbacks when schemas are present (skipped automatically when running in minimal mode), and `lib/io.sh` rejects batched (`[...]`) input after trimming whitespace.
- Integration coverage also verifies: `notifications/cancelled` is ignored for `initialize`, subscriptions are server-managed throughout their lifetime, progress tokens accept only strings/numbers, capability downgrades occur when JSON tooling is unavailable, and Python fallback responses remain spec-compliant.
- HTTP integration tests confirm Streamable HTTP behavior: missing/invalid `MCP-Protocol-Version` yields 400, requests lacking a required `Mcp-Session-Id` yield 400, `DELETE` with `Mcp-Session-Id` terminates the session, and post-termination requests return 404.
- Also verify that requests specifying `Accept: application/json, text/event-stream` receive compliant responses and that legacy HTTP+SSE endpoints remain available for backward compatibility tests.
- Proxy compatibility tests route the stdio stream through a mock Streamable HTTP/SSE bridge to prove one-line JSON framing, absence of stray stderr, and correct propagation of `_meta` fields that production gateways rely on (without shipping an HTTP stack in-core).
- Compatibility smoke suites run against the latest official MCP SDKs (Python/TypeScript) and the MCP Inspector tool to ensure cross-client parity.
- Stress tests exercise 100 concurrent tool calls, long-running jobs (≥5 minutes), stdout flooding attempts, empty directories, circular symlinks, and resource exhaustion scenarios (file descriptors, disk usage) to verify graceful degradation.
- Future enhancements may include stress/performance scenarios, long-running tool simulations, and regression harnesses for newly added transports.

### 18.1 Test Harness Layout

All tests live under `test/` with the following structure:

```
test/
├─ lint.sh
├─ smoke.sh
├─ unit/
│  ├─ lock.bats
│  ├─ paginate.bats
│  ├─ json.bats
│  └─ run.sh
├─ integration/
│  ├─ fixtures/               # reusable tool/resource/prompt trees
│  ├─ test_capabilities.sh
│  ├─ test_resources.sh
│  ├─ test_prompts.sh
│  ├─ test_completion.sh
│  └─ run.sh
├─ stress/
│  ├─ test_concurrency.sh
│  ├─ test_long_running.sh
│  ├─ test_output_guard.sh
│  └─ run.sh
├─ compatibility/
│  ├─ inspector.sh
│  ├─ sdk_typescript.sh
│  ├─ http_proxy.sh
│  └─ run.sh
└─ common/
   ├─ env.sh                 # exported PATH/TMPDIR helpers
   ├─ assert.sh              # reusable Bash assertions
   └─ fixtures.sh            # copy fixture folders, compare outputs
```

Common helpers (`test/common/*.sh`) centralise environment prep, assertions, and fixture copying so each test script stays portable (Bash 3.2, macOS/Linux/Windows Git-Bash). `run.sh` wrappers orchestrate the individual scripts and return non-zero on failure.

### 18.2 Test Layer Responsibilities

| Layer            | Script(s)                          | Purpose                                                                                     |
|------------------|------------------------------------|---------------------------------------------------------------------------------------------|
| Lint             | `test/lint.sh`                     | Run `shellcheck` and `shfmt -d` on the tracked shell scripts.                               |
| Unit             | `test/unit/*.bats`, `run.sh`       | Bats-based modules (`lib/lock.sh`, `lib/paginate.sh`, JSON helpers).                        |
| Smoke            | `test/smoke.sh`                    | Fast initialize → `tools/list` → `tools/call` sanity check.                                 |
| Integration      | `test/integration/run.sh`          | Exercises lifecycle, tools/resources/prompts/completion, pagination, cancellation, minimal mode, Python fallback using fixture directories. |
| Examples         | `test/examples/run.sh`             | Replays `examples/00`–`08` ladder, verifying README transcripts and Windows CRLF handling. |
| Stress           | `test/stress/run.sh`               | 100 concurrent tool calls, ≥5 minute tool watchdog, output-size guard, resource exhaustion. |
| Compatibility    | `test/compatibility/run.sh`        | MCP Inspector, official SDKs (Python/TypeScript), Streamable HTTP/SSE proxy compliance.    |

Scripts share assertion helpers (e.g., `assert_eq`, `assert_contains`). `set -euo pipefail` and `trap` cleanup are required so failures surface immediately and temporary directories are removed.

### 18.3 CI Pipeline

`.github/workflows/ci.yml` runs the suite in distinct jobs:

```yaml
jobs:
  lint:
    runs-on: ubuntu-latest
    steps: … run test/lint.sh
  unit:
    runs-on: ubuntu-latest
    steps: … run test/unit/run.sh
  integration:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - run: test/smoke.sh
      - run: test/integration/run.sh
      - run: test/examples/run.sh
  stress:
    runs-on: ubuntu-latest
    if: github.event_name == 'schedule'
    steps: … run test/stress/run.sh
  compatibility:
    runs-on: ubuntu-latest
    needs: integration
    steps: … run test/compatibility/run.sh
```

Windows jobs use Git-Bash (`shell: bash`). Stress tests execute on a scheduled workflow to avoid slowing PR feedback. Each script emits human-readable results (`✅/❌` or TAP-style) and exits non-zero on failure; known experimental scenarios (e.g., Windows quirks) may log warnings but must not hide regressions.

## 19. Roadmap Highlights
- Provide vetted installation guidance (URLs + checksums) for `jq`/`gojq`, and optionally ship verified static binaries for common platforms (macOS, Linux) with checksum validation at startup—never auto-download without explicit `MCPBASH_INSTALL_DEPS=true`.
- Publish a lightweight `contrib/http-proxy/` (Go or Node) intended **only for local testing and demos** that bridges stdio mcp-bash to Streamable HTTP and, optionally, legacy HTTP+SSE. This minimal proxy must:
  - Return `Mcp-Session-Id` (when sessions are enabled) on initialization responses and require it on subsequent HTTP requests; support `DELETE` with the header to terminate sessions, returning 404 thereafter.
  - Require clients to include `MCP-Protocol-Version` on all subsequent HTTP requests and reject unsupported versions with 400-level responses.
  - Respond correctly when clients send `Accept: application/json, text/event-stream` (as mandated by the Streamable HTTP transport) and surface legacy HTTP+SSE endpoints for clients that have not upgraded yet.
  - Validate `Origin` and bind to `127.0.0.1` by default, printing a loud “not for production” warning at startup.
- For production deployments, recommend existing, battle-tested MCP gateways (e.g., Microsoft MCP Gateway, Docker MCP Gateway, community-maintained proxies) rather than attempting to harden the demo proxy; documentation should clearly differentiate these tiers.
- Ship an `examples/proxy/` directory with copy-pasteable configs for Microsoft MCP Gateway, Docker MCP Gateway, and a generic reverse proxy, illustrating how to forward newline-delimited JSON between stdio and Streamable HTTP/SSE endpoints while propagating session headers and OAuth tokens.
- Author `docs/REMOTE.md` describing remote connectivity options: (a) a Bash + `socat` demo proxy for local experimentation that prints a “not for production” warning on start, and (b) hardened production proxy choices (Go binary, Node service, managed platforms such as Microsoft MCP Gateway or Docker MCP Gateway) with deployment guidance, session header mapping, timeout recommendations, and security considerations.
- Extend the `server.d/env.sh` template and reference docs to expose proxy-facing toggles (`MCPBASH_SESSION_ID_HINT`, trusted-origin allow lists, concurrency overrides) so operators can integrate with enterprise gateways without patching core scripts.
- Build an opinionated, cross-platform `examples/` suite that onboards developers quickly while exercising critical protocol behaviors:
  - **Design principles**: laddered learning (each example introduces exactly one new MCP/Bash concept), zero-setup execution (`./examples/run <id>` copies the example overlay into a temp workspace and execs `bin/mcp-bash`), README transcripts that show JSON-RPC request/response pairs, prereq matrices that call out jq/gojq/Python fallbacks, and five-minute “win” checklists.
  - **Execution harness**: provide shared utilities in `examples/run` (Bash 3.2-safe; prints detected JSON tooling), `examples/send` (single JSON-RPC emitter for transcripts), `examples/check-env` (diagnostics for CRLF, Python availability, jq detection), and an `examples/fixtures/` directory reused across scenarios. Harness must symlink `bin/`, `lib/`, `handlers/`, `providers/`, and `sdk/` into the temp workspace and respect the `mcp_…` SDK naming that already parses on Bash 3.2.
  - **Example ladder**:
    - **P0 (must-have)**: `00-hello-tool`, `01-args-and-validation`, `02-logging-and-levels`, `03-progress-and-cancellation`, `04-timeouts`, `05-pagination-basics`, `06-resources-file-provider`, `07-prompts-and-rendering`, `08-completion`.
    - **P1 (reliability/portability)**: `09-large-output-and-truncation`, `10-structured-output-deep`, `11-windows-paths`, `12-minimal-mode-diagnostics`, `13-error-catalog`, `14-manual-registration`, `15-process-groups-and-kill`.
    - **P2 (integration/transport)**: `16-http-proxy-smoke`, `17-batch-compat`, `18-registry-live-update`, `19-stress-suite`.
  - **README contract**: every example documents prerequisites, the exact `./examples/run` invocation, 2–5 line JSON-RPC transcripts (single-line JSON responses), learning outcomes tied to spec sections, and top troubleshooting tips (Python missing, CRLF, jq absent). Examples that rely on structured output must demonstrate both the structured payload and text fallback.
  - **Acceptance coverage**: add CI tests (`test/examples/NN-*.bats` or equivalent Bash harness) that launch each example via `./examples/run`, feed canned NDJSON input (including CRLF variants on Windows runners), assert that every line is valid single-line JSON, and verify properties such as `hasMore`, `_meta.exitCode`, progress throttling, cancellation timing, and timeout errors.
  - **Opinionated defaults**: showcase integer-second timeouts, explicitly log detected JSON tooling, reinforce process-group cancellation, highlight BOM/CRLF stripping, and prefer structured output plus text fallback when JSON tooling is present.
  - **Scaffolding tie-in**: deliver `bin/mcp-bash scaffold tool <name>` that copies a vetted template derived from `00-hello-tool`, including metadata with an `outputSchema`, Python fallback patterns, commented-out progress/logging helpers, and a README linking to follow-on examples (02/03).
- Add built-in resource providers for `git://` and `https://` URIs.
- Extend scaffolding generators beyond the tool template (e.g., prompt/resource scaffolds) once the initial `bin/mcp-bash scaffold tool <name>` helper ships.
- Explore advanced spec features such as resource links in tool outputs, elicitation flows, and OAuth-based authorization guidance for remote deployments, documenting their feasibility and client support.

## 20. Versioning and Release Management
- Core scripts are semantically versioned under `serverInfo.version`.
- Breaking protocol changes require a major version bump and migration notes in `docs/PORTABILITY.md`.
- Auto-generated files (`registry/*.json`) are excluded from releases; they regenerate on server start.

## 21. Outstanding Decisions
- Implement dynamic acquisition of `gojq` when neither `gojq` nor `jq` is installed or when the detected version is older than the minimum supported release (use the installation instructions recommended by the `gojq` project and cache the binary under `bin/deps/`); Python fallback remains the default when binaries are absent.
- Auto-installation must remain opt-in (e.g., gated behind `MCPBASH_INSTALL_GOJQ=true`) so security-conscious or offline deployments can remain in degraded mode with clear logging instead of silent network activity.
- Document production-grade proxy and hosting options—no code required in-core—including managed MCP hosting in Microsoft Dev Containers/Docker, OpenAI-hosted transports, and community-maintained HTTP/SSE bridges, so users can choose the best fit for remote connectivity.
- Author companion documents (`docs/ERRORS.md`, `docs/SECURITY.md`, `docs/LIMITS.md`, `docs/WINDOWS.md`) to capture the operational guidance summarized here in greater detail before GA.
