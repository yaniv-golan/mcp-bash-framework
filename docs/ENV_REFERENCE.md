# Environment Reference

Authoritative list of supported environment variables. Defaults shown are the shipped values; caps noted where applicable.

## User-Facing Configuration

| Variable | Default | Notes |
|----------|---------|-------|
| `MCPBASH_PROJECT_ROOT` | (required for MCP clients) | Project root containing `tools/`, `resources/`, `prompts/`, `server.d/`. |
| `MCPBASH_TOOLS_DIR` / `MCPBASH_RESOURCES_DIR` / `MCPBASH_PROMPTS_DIR` / `MCPBASH_SERVER_DIR` | Derived from `MCPBASH_PROJECT_ROOT` | Override content and server hook locations. `doctor`, `run-tool` and `validate` honour `MCPBASH_SERVER_DIR` (output labels stay relative to the project); `bundle` does not (it always packages `server.d/`). |
| `MCPBASH_PROVIDERS_DIR` | `${MCPBASH_PROJECT_ROOT}/providers` | Directory for project-level resource providers. Scripts here are checked before framework providers. Unlike other content directories, not auto-created. |
| `MCPBASH_HOME` | (install dir of `bin/mcp-bash`) | Framework install location. Override to run framework code from another checkout (development). |
| `MCPBASH_MODERN_PROTOCOL` | `false` | `true` serves MCP 2026-07-28 (modern, stateless) requests next to the legacy `initialize` session, and answers `server/discover`. Off by default in 2.0 while roots, elicitation and `subscriptions/listen` are missing on that path: a client that goes modern (Claude Code does when `server/discover` succeeds) gets no client roots (only `MCPBASH_ROOTS`, `config/roots.json` or the project root), no elicitation and no list-change notifications. Needs jq/gojq. With the switch on, the server sends no log notification before a legacy client's `initialize` (a modern-only process has no session for unsolicited messages). See [ARCHITECTURE.md](ARCHITECTURE.md#modern-requests-mcp-2026-07-28). |
| `MCPBASH_MODERN_LIST_TTL_MS` | `5000` (`0` when `MCPBASH_LOG_LEVEL=debug`) | `ttlMs` caching hint on `server/discover` and the list results sent to modern clients. |
| `MCPBASH_MODERN_READ_TTL_MS` | `0` | `ttlMs` caching hint on `resources/read` results sent to modern clients. |
| `MCPBASH_MODERN_CACHE_SCOPE` | `private` | `cacheScope` caching hint (`private` or `public`) on those results. The lists depend on the operator's allowlist and environment, so keep `private` unless every client may share them. |
| `MCPBASH_ROOTS` | (unset) | Colon-separated fallback roots, used when the client does not provide roots. Each path must exist. |
| `MCP_TOOLS_TTL` / `MCP_RESOURCES_TTL` / `MCP_PROMPTS_TTL` | `5` | Seconds a discovered registry stays fresh before a list/call rescans. `run-tool` uses a one-year TTL so it never rescans mid-run. |
| `MCPBASH_REGISTRY_DIR` | `$MCPBASH_PROJECT_ROOT/.registry` | Registry cache location. |
| `MCPBASH_REGISTRY_MAX_BYTES` | `104857600` | Registry size guard (bytes). |
| `MCPBASH_REGISTRY_REFRESH_PATH` | (unset) | Limit registry refresh to a subpath (must be a literal subpath of the default scan dir; no glob semantics). |
| `MCPBASH_STATIC_REGISTRY` | (unset) | When `1`, skip runtime discovery and use pre-generated `.registry/*.json` cache directly. Designed for bundle deployments. Skips `register.sh` (shell code) but honors `register.json` (data-only). Falls back to normal discovery if cache missing. CLI `registry refresh` still works (overrides static mode). |
| `MCPBASH_DEPRECATION_NOTICE` | `true` | When the project uses APIs that change in mcp-bash 2.0, the server prints one line to stderr at startup, at most once a day (stamp: `deprecation-notice.stamp` in the registry dir). `false` turns off the stderr line only: the scan still runs in the background (when a project file or the rules changed since the last scan, at most once an hour per project; otherwise its last result is reused) and writes `removed-api.findings` (files that call SDK helpers removed in 2.0) in the registry dir, which adds a note to the `initialize` and `server/discover` instructions while it is non-empty. The scan is skipped for bundles (`MCPBASH_STATIC_REGISTRY=1`), vendored runtimes, minimal mode and a read-only registry dir. Details: `mcp-bash validate`. |
| `MCPBASH_MAX_CONCURRENT_REQUESTS` | `16` | Worker slot cap. |
| `MCPBASH_LOCK_POLL_INTERVAL` | `0.02` | Seconds between attempts while waiting for an internal lock (stdout and others). |
| `MCPBASH_LOCK_REAP_GRACE_SECS` | `1` | Seconds a lock with no owner recorded yet is left alone (its creator may still be writing it) before a waiter removes it. |
| `MCPBASH_LOCK_REAP_GUARD_STALE_SECS` | `5` | Seconds after which a lock-cleanup guard left by a process that died is cleared. |
| `MCPBASH_MAX_TEXT_BYTES` | `102400` | Max bytes for `content[].text` in `mcp_result_json` before the text is replaced by a short summary (the data stays in `structuredContent`; 100KB default ensures LLMs see full data). |
| `MCPBASH_MAX_TOOL_OUTPUT_SIZE` | `10485760` | Tool stdout limit (bytes). |
| `MCPBASH_MAX_TOOL_STDERR_SIZE` | `$MCPBASH_MAX_TOOL_OUTPUT_SIZE` | Tool stderr limit (bytes). Over either limit, the call returns an `output_too_large` error result. |
| `MCPBASH_TOOL_STDERR_CAPTURE` | `true` | Attach the tool's stderr tail to its result (`_meta.stderr`). For a tool that exits non-zero the tail is also the error text the model reads, so set `false` for tools that may print secrets to stderr. |
| `MCPBASH_TOOL_STDERR_TAIL_LIMIT` | `4096` | Bytes of stderr kept for `_meta.stderr`; also the cap on a failed tool's error text. |
| `MCPBASH_MAX_RESOURCE_BYTES` | `$MCPBASH_MAX_TOOL_OUTPUT_SIZE` | Resource payload limit (bytes). `file://` reads stop at this size. A value that is not a plain byte count (such as `1M` or `-1`) means 10 MiB. |
| `MCPBASH_MAX_UI_RESOURCE_BYTES` | `1048576` | Max size of a `ui://` resource (bytes). A value that is not a plain byte count (such as `1M`) means the default. |
| `MCPBASH_MAX_PROGRESS_PER_MIN` | `100` | Progress events per request per minute. |
| `MCPBASH_MAX_LOGS_PER_MIN` | `$MCPBASH_MAX_PROGRESS_PER_MIN` | Log events per request per minute. |
| `MCPBASH_DEFAULT_TOOL_TIMEOUT` | `30` | Default tool timeout (seconds); also applies to `tools/list`. |
| `MCPBASH_DEFAULT_SUBSCRIBE_TIMEOUT` | `120` | Default `resources/subscribe` timeout (seconds); `0` disables it. A subscribe that times out gets a `-32603` error. |
| `MCPBASH_DEFAULT_RESOURCE_TIMEOUT` | `120` | Default `resources/read` timeout (seconds); `0` disables it. A read that runs longer is stopped and the client gets a `-32603` error. A request's `params.timeoutSecs` overrides it for that request. |
| `MCPBASH_SHUTDOWN_TIMEOUT` | `5` | Graceful shutdown timeout (seconds). |
| `MCPBASH_IDLE_TIMEOUT` | `3600` | Seconds to wait for client activity before exiting (0 = disabled). Prevents zombie processes when clients disconnect without shutdown. |
| `MCPBASH_IDLE_TIMEOUT_ENABLED` | `true` | Set to `false` to disable idle timeout entirely. |
| `MCPBASH_ORPHAN_CHECK_ENABLED` | `true` (Unix), `false` (Windows/CI) | Enable parent-death detection. Server exits if original parent process dies. Disabled by default when `MCPBASH_CI_MODE=true`. |
| `MCPBASH_ORPHAN_CHECK_INTERVAL` | `30` | Seconds between orphan detection checks. |
| `MCPBASH_PROGRESS_EXTENDS_TIMEOUT` | `false` | When `true`, each progress emission or pattern match restarts the tool's `timeoutSecs` watchdog, so a long-running tool continues as long as it shows activity, up to `MCPBASH_MAX_TIMEOUT_SECS`. Unrelated to `MCPBASH_IDLE_TIMEOUT` (client silence). |
| `MCPBASH_MAX_TIMEOUT_SECS` | `600` | Hard cap on tool runtime (seconds) when progress-aware timeout is enabled. |
| `MCPBASH_LOG_LEVEL` | `info` | RFC-5424 level; `debug` shows discovery traces. Boolean values `true`/`1` are normalized to `debug`, `false`/`0` to `info`. Can also be enabled via `server.d/.debug` file (only when env var is unset; see [DEBUGGING.md](DEBUGGING.md#debug-file-persistent-debug-mode)). |
| `MCPBASH_LOG_VERBOSE` | (unset) | `true` logs full paths/manual registration output (security risk). |
| `MCPBASH_CI_MODE` | `false` | CI defaults: safe tmp/log dirs, keep logs, timestamps, failure summary/env snapshot, GH annotations when tracing provides file/line. |
| `MCPBASH_CI_VERBOSE` | `false` | With `MCPBASH_CI_MODE=true`, default the log level to `debug` instead of `info`. |
| `MCPBASH_KEEP_LOGS` | `false` (`true` in CI mode) | Keep the state dir (logs, traces) after exit and print its path. |
| `MCPBASH_LOG_DIR` | (unset; a temp dir in CI mode) | Directory for traces, per-tool debug logs and `failure-summary.jsonl`. Falls back to the state dir. Must not be a symlink. |
| `MCPBASH_TRACE_TOOLS` | `false` | `true`/`1` runs shell tools under `set -x`, writing the trace to a per-invocation file. |
| `MCPBASH_TRACE_PS4` | `+ ${BASH_SOURCE[0]##*/}:${LINENO}: ` | `PS4` prefix used for tool traces. |
| `MCPBASH_TRACE_MAX_BYTES` | `1048576` | Size cap for each tool trace file (bytes). |
| `MCPBASH_ENABLE_LIVE_PROGRESS` | `false` | Stream progress/logs during tool execution (starts a background flusher); when `false`, progress/logs are emitted at completion. |
| `MCPBASH_PROGRESS_FLUSH_INTERVAL` | `0.5` | Flush cadence (seconds) when live progress is enabled. |
| `MCPBASH_RESOURCES_POLL_INTERVAL_SECS` | `2` | Resource subscription polling interval (poller starts after first `resources/subscribe`); `0` to disable polling. |
| `MCPBASH_ENV_PAYLOAD_THRESHOLD` | `65536` | Spill args/metadata to temp files above this many bytes. |
| `MCPBASH_TOOL_ENV_MODE` | `minimal` | Tool env isolation: `minimal`, `inherit`, or `allowlist`. `minimal` keeps PATH/HOME/TMPDIR/LANG, Windows system variables, `MCPBASH_*` (never `MCPBASH_REMOTE_TOKEN*`) and only the framework-owned `MCP_*` families (see [SECURITY.md](SECURITY.md)); other `MCP_*` names need `allowlist`. Also settable from `server.meta.json` `"env"`; the launch env wins. |
| `MCPBASH_TOOL_ENV_ALLOWLIST` | (unset) | Extra env names when `MCPBASH_TOOL_ENV_MODE=allowlist`. Also settable from `server.meta.json` `"env"`; the launch env wins. |
| `MCPBASH_TOOL_ENV_INHERIT_ALLOW` | `false` | Must be `true` to allow `MCPBASH_TOOL_ENV_MODE=inherit`. |
| `MCPBASH_PROVIDER_ENV_MODE` | `isolate` | Provider env isolation (completion/resource providers): `isolate`, `inherit`, or `allowlist`. `isolate` keeps the same framework-owned `MCP_*` families as tools; other `MCP_*` names need `allowlist`. Prompts ignore this setting. Also settable from `server.meta.json` `"env"`; the launch env wins. |
| `MCPBASH_PROVIDER_ENV_ALLOWLIST` | (unset) | Extra env names when `MCPBASH_PROVIDER_ENV_MODE=allowlist`. Also settable from `server.meta.json` `"env"`; the launch env wins. |
| `MCPBASH_PROVIDER_ENV_INHERIT_ALLOW` | `false` | Must be `true` to allow `MCPBASH_PROVIDER_ENV_MODE=inherit`. |
| `MCPBASH_COMPLETION_TIMEOUT_SECS` | `5` | Timeout for per-prompt and per-resource completion scripts (`0` disables). Registered completions use their own `timeoutSecs`, or `MCPBASH_COMPLETION_REGISTERED_TIMEOUT_SECS`. |
| `MCPBASH_COMPLETION_REGISTERED_TIMEOUT_SECS` | `30` | Timeout for registered completions (`register.json` / `register.sh`) that do not set `timeoutSecs` (`0` disables). An explicit `timeoutSecs` always wins; `timeoutSecs: 0` means no timeout. |
| `MCPBASH_IGNORE_META_ENV` | `false` | Operator switch: when `true`, ignore the `"env"` object in `server.d/server.meta.json`. `mcp-bash run-tool --print-env` and `mcp-bash doctor` show which source (launch env, `server.meta.json`, default) decides each scope, with names and states only (never values). `--print-env` reflects the launch env plus `server.meta.json`, not `--with-server-env`/`--source` files or `server.d/policy.sh`. |
| `MCPBASH_TOOL_ALLOWLIST` | (required) | Space/comma-separated tool names allowed to run (`*` to allow all). Empty by default (deny). |
| `MCPBASH_TOOL_ALLOW_DEFAULT` | `deny` | Set to `allow` to keep legacy allow-all behavior without an explicit allowlist. |
| `MCPBASH_FORCE_MINIMAL` | (unset) | Force minimal capability tier even when JSON tooling is present. |
| `MCPBASH_JSON_TOOL` | (auto-detect jq → gojq) | Explicit JSON tool selection: `jq`, `gojq`, or `none`. Default order is jq-first (Windows E2BIG mitigation). |
| `MCPBASH_JSON_TOOL_BIN` | (derived from tool) | Explicit path to JSON tool; infers `MCPBASH_JSON_TOOL` from basename if unset and treats unknown names as jq-compatible (behavior may differ if flags differ). |
| `MCPBASH_ALLOW_JSON_TOOL_OVERRIDE_FOR_ROOT` | `false` | Allow `MCPBASH_JSON_TOOL{,_BIN}` overrides when running as root. |
| `MCPBASH_COMPAT_BATCHES` | (unset) | Enable legacy batch request support (auto-enabled when protocol is `2025-03-26`; use only for out-of-spec clients on newer protocols). Removed in 2.0, where batches stay automatic for `2025-03-26` only. <!-- lint-api-usage: allow --> |
| `MCPBASH_DEBUG_PAYLOADS` | (unset) | Write full message payloads to `${TMPDIR}/mcpbash.state.*`. |
| `MCPBASH_DEBUG_ERRORS` | `false` | When `true`, include tool diagnostics (exit code, stderr tail, trace line) in outputSchema validation errors. |
| `MCPBASH_DEBUG_LOG` | (unset) | Override the per-tool debug log path; when unset, tools get a per-invocation file under the log/state dir. |
| `MCPBASH_DEBUG` | `false` | Enable debug EXIT trap that logs exit location and call stack on non-zero exits; helps diagnose `set -e` failures. |
| `MCPBASH_DEBUG_ALL_EXITS` | `false` | With `MCPBASH_DEBUG=true`, log all exits (not just failures). |
| `MCPBASH_PRESERVE_STATE` | (unset) | Preserve state dir after exit (useful with `MCPBASH_DEBUG_PAYLOADS`; includes per-request `stderr.*.log` worker captures). |
| `MCPBASH_REMOTE_TOKEN` | (unset) | Shared secret for proxied deployments (minimum 32 characters). `MCPBASH_REMOTE_TOKEN*` is removed from tool and provider environments (except `inherit` mode), and the token keys are deleted from the `_meta` passed to tools. |
| `MCPBASH_REMOTE_TOKEN_KEY` | `mcpbash/remoteToken` | JSON path for token lookup. |
| `MCPBASH_REMOTE_TOKEN_FALLBACK_KEY` | `remoteToken` | Alternate JSON path for token lookup. |
| `MCPBASH_REMOTE_TOKEN_MAX_FAILURES_PER_MIN` | `10` | Max failed remote-token attempts per minute before throttling responses. |
| `MCPBASH_HTTPS_ALLOW_HOSTS` / `MCPBASH_HTTPS_DENY_HOSTS` | (unset) | HTTPS provider host allow/deny lists; private/loopback always blocked. **Allow list is required** unless `MCPBASH_HTTPS_ALLOW_ALL=true`. HTTPS fetches use curl and pin resolved IPs via `--resolve` (DNS rebinding mitigation). |
| `MCPBASH_HTTPS_ALLOW_ALL` | `false` | Explicitly allow all public HTTPS hosts (unsafe; prefer `MCPBASH_HTTPS_ALLOW_HOSTS`). |
| `MCPBASH_HTTPS_TIMEOUT` | `15` (cap ≤60s) | HTTPS provider timeout. |
| `MCPBASH_HTTPS_MAX_BYTES` | `10485760` (cap ≤20MB) | HTTPS payload size guard. |
| `MCPBASH_HTTPS_USER_AGENT` | (unset) | Custom User-Agent for HTTPS provider requests. SDK helper `mcp_download_safe` sets `mcpbash/<version> (tool-sdk)` by default. |
| `MCPBASH_ENABLE_GIT_PROVIDER` | `false` | Enable Git resource provider (`git+https://` URIs). |
| `MCPBASH_GIT_ALLOW_HOSTS` / `MCPBASH_GIT_DENY_HOSTS` | (unset) | Allow/deny lists; private/loopback always blocked. Allow list (or `MCPBASH_GIT_ALLOW_ALL=true`) is required when the git provider is enabled. |
| `MCPBASH_GIT_ALLOW_ALL` | `false` | Explicitly allow all git hosts (unsafe; prefer `MCPBASH_GIT_ALLOW_HOSTS`). |
| `MCPBASH_GIT_TIMEOUT` | `30` (cap ≤60s) | Git provider timeout (seconds). |
| `MCPBASH_GIT_MAX_KB` | `51200` (cap ≤1048576) | Git repository size guard (KB). |
| `MCPBASH_CORRUPTION_WINDOW` | `60` | Stdout corruption tracking window (seconds). |
| `MCPBASH_CORRUPTION_THRESHOLD` | `3` | The server stops when this many corruption events (multi-line or non-UTF-8 payloads) occur within the window. A failed write to stdout stops it at once. |
| `MCPBASH_ALLOW_CORRUPT_STDOUT` | `false` | `true` keeps the server running past the corruption threshold (events are still logged). It does not cover a failed write to stdout (including a transient error such as `EAGAIN` or a full disk when stdout is a file), which always stops the server. |
| `MCPBASH_MAX_MANUAL_REGISTRY_BYTES` | `1048576` | Max bytes accepted from manual registration inputs: `server.d/register.json` file size and `server.d/register.sh` captured stdout/stderr output. |
| `MCPBASH_ALLOW_PROJECT_HOOKS` | `false` | Must be `true` to execute project `server.d/register.sh` hooks. Refused if file is group/world-writable or ownership mismatches. |
| `MCPBASH_FRAMEWORK_VERSION` | (auto) | Framework version from `${MCPBASH_HOME}/VERSION`. Read-only, set automatically at startup. |

### Prompt templating

- Only `{{var}}` placeholders are substituted (values come from `prompts/get` `arguments`).
- Other placeholder syntaxes are not processed.

Example allowlist usage to keep tool env minimal while letting HOME/PATH through:

```bash
MCPBASH_TOOL_ENV_MODE=allowlist MCPBASH_TOOL_ENV_ALLOWLIST=HOME,PATH mcp-bash ...
```

## Runtime directories

Operators may set these; the defaults suit most setups. The server refuses to start if `MCPBASH_STATE_DIR` or `MCPBASH_LOCK_ROOT` is a symlink (see [SECURITY.md](SECURITY.md)). What the server writes inside them is internal.

| Variable | Default | Notes |
|---|---|---|
| `MCPBASH_TMP_ROOT` | `TMPDIR`, else `/tmp` (CI mode: the runner's temp dir) | Parent of the per-process state directory. Set it to a short, writable path when the default is too long (Windows) or not writable. |
| `MCPBASH_STATE_DIR` | a new `mktemp -d` directory (mode 0700) under `MCPBASH_TMP_ROOT` | Per-process runtime state (worker files, logs, traces). A directory the server created is removed on exit unless `MCPBASH_PRESERVE_STATE=true` or `MCPBASH_KEEP_LOGS=true`; one you set is never removed. |
| `MCPBASH_LOCK_ROOT` | `<state dir>/locks` | Lock directories (stdout and others). |

## Internal Runtime State (do not override)

Examples: `MCPBASH_STDOUT_LOCK_NAME`, `MCPBASH_INITIALIZED`, `MCPBASH_ROOTS_*` (not to be confused with the user-facing `MCPBASH_ROOTS`), `MCPBASH_CLIENT_SUPPORTS_*`, `MCPBASH_PROGRESS_FLUSHER_PID`, `MCPBASH_RESOURCE_POLL_PID`, `MCPBASH_NEXT_OUTGOING_ID`, `MCPBASH_HANDLER_OUTPUT`. These are set by the runtime to coordinate sourced scripts and are not user-facing.

Tools can read two of them, and should not set them:
- `MCPBASH_PROTOCOL_ERA`: `modern` for a 2026-07-28 request, unset otherwise. `mcp_result_json` reads it.
- `MCPBASH_CLIENT_SUPPORTS_UI`: `1` when the client supports MCP Apps (`mcp_client_supports_ui`).

The server clears both at startup, so values in its own environment (for example in an mcp-bash started by a tool) are ignored.

## Test/Scaffold/Installer Helpers

| Variable | Default | Notes |
|----------|---------|-------|
| `MCPBASH_RUN_TOOL_SOURCE_SERVER_ENV` | (unset) | When `true` or `1`, `mcp-bash run-tool` implicitly sources `server.d/env.sh` before tool execution (equivalent to `--with-server-env` flag). Useful in CI pipelines where all `run-tool` invocations should use server environment. |
| `MCPBASH_INTEGRATION_DEBUG_FAILED` | `false` | Re-run failed integration tests with `bash -x` tracing. |

Examples: `MCPBASH_BASE_TAR` / `MCPBASH_BASE_TAR_META` / `MCPBASH_BASE_TAR_KEY`, `MCPBASH_STAGING_TAR`, `MCPBASH_TEST_ROOT`, `MCPBASH_INTEGRATION_TMP`, `MCPBASH_RUN_SDK_TYPESCRIPT`, `MCPBASH_LOG_JSON_TOOL` (suite logging), integration runner controls (`MCPBASH_INTEGRATION_ONLY`, `MCPBASH_INTEGRATION_SKIP`, `MCPBASH_INTEGRATION_TEST_TIMEOUT_SECONDS`, `MCPBASH_INTEGRATION_DEBUG_FAILED`), schema conformance test (`MCPBASH_JV_BIN`, `MCPBASH_CONFORMANCE_REQUIRE_SCHEMA`, `MCPBASH_CONFORMANCE_OUT`, `MCPBASH_CONFORMANCE_SERVER_JSON_TOOL`), installer overrides (`MCPBASH_INSTALL_REPO_URL`). Keep these scoped to testing or packaging workflows. 
