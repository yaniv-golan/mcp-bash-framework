# Environment Reference

Authoritative list of supported environment variables. Defaults shown are the shipped values; caps noted where applicable.

## User-Facing Configuration

| Variable | Default | Notes |
|----------|---------|-------|
| `MCPBASH_PROJECT_ROOT` | (required for MCP clients) | Project root containing `tools/`, `resources/`, `prompts/`, `server.d/`. |
| `MCPBASH_TOOLS_DIR` / `MCPBASH_RESOURCES_DIR` / `MCPBASH_PROMPTS_DIR` / `MCPBASH_SERVER_DIR` | Derived from `MCPBASH_PROJECT_ROOT` | Override content and server hook locations. |
| `MCPBASH_PROVIDERS_DIR` | `${MCPBASH_PROJECT_ROOT}/providers` | Directory for project-level resource providers. Scripts here are checked before framework providers. Unlike other content directories, not auto-created. |
| `MCPBASH_REGISTRY_DIR` | `$MCPBASH_PROJECT_ROOT/.registry` | Registry cache location. |
| `MCPBASH_REGISTRY_MAX_BYTES` | `104857600` | Registry size guard (bytes). |
| `MCPBASH_REGISTRY_REFRESH_PATH` | (unset) | Limit registry refresh to a subpath (must be a literal subpath of the default scan dir; no glob semantics). |
| `MCPBASH_STATIC_REGISTRY` | (unset) | When `1`, skip runtime discovery and use pre-generated `.registry/*.json` cache directly. Designed for bundle deployments. Skips `register.sh` (shell code) but honors `register.json` (data-only). Falls back to normal discovery if cache missing. CLI `registry refresh` still works (overrides static mode). |
| `MCPBASH_MAX_CONCURRENT_REQUESTS` | `16` | Worker slot cap. |
| `MCPBASH_MAX_TEXT_BYTES` | `102400` | Max bytes for `content[].text` in `mcp_result_success` before summarization (100KB default ensures LLMs see full data). |
| `MCPBASH_MAX_TOOL_OUTPUT_SIZE` | `10485760` | Tool stdout limit (bytes). |
| `MCPBASH_MAX_TOOL_STDERR_SIZE` | `$MCPBASH_MAX_TOOL_OUTPUT_SIZE` | Tool stderr limit (bytes). |
| `MCPBASH_MAX_RESOURCE_BYTES` | `$MCPBASH_MAX_TOOL_OUTPUT_SIZE` | Resource payload limit (bytes). |
| `MCPBASH_MAX_PROGRESS_PER_MIN` | `100` | Progress events per request per minute. |
| `MCPBASH_MAX_LOGS_PER_MIN` | `$MCPBASH_MAX_PROGRESS_PER_MIN` | Log events per request per minute. |
| `MCPBASH_DEFAULT_TOOL_TIMEOUT` | `30` | Default tool timeout (seconds). |
| `MCPBASH_DEFAULT_SUBSCRIBE_TIMEOUT` | `120` | Default `resources/subscribe` timeout (seconds). |
| `MCPBASH_SHUTDOWN_TIMEOUT` | `5` | Graceful shutdown timeout (seconds). |
| `MCPBASH_PROGRESS_EXTENDS_TIMEOUT` | `false` | When `true`, progress emissions reset the idle timeout, allowing long-running tools to continue as long as they report progress. |
| `MCPBASH_MAX_TIMEOUT_SECS` | `600` | Hard cap on tool runtime (seconds) when progress-aware timeout is enabled. |
| `MCPBASH_LOG_LEVEL` | `info` | RFC-5424 level; `debug` shows discovery traces. Can also be enabled via `server.d/.debug` file (see [DEBUGGING.md](DEBUGGING.md#debug-file-persistent-debug-mode)). |
| `MCPBASH_LOG_VERBOSE` | (unset) | `true` logs full paths/manual registration output (security risk). |
| `MCPBASH_CI_MODE` | `false` | CI defaults: safe tmp/log dirs, keep logs, timestamps, failure summary/env snapshot, GH annotations when tracing provides file/line. |
| `MCPBASH_ENABLE_LIVE_PROGRESS` | `false` | Stream progress/logs during tool execution (starts a background flusher); when `false`, progress/logs are emitted at completion. |
| `MCPBASH_PROGRESS_FLUSH_INTERVAL` | `0.5` | Flush cadence (seconds) when live progress is enabled. |
| `MCPBASH_RESOURCES_POLL_INTERVAL_SECS` | `2` | Resource subscription polling interval (poller starts after first `resources/subscribe`); `0` to disable polling. |
| `MCPBASH_ENV_PAYLOAD_THRESHOLD` | `65536` | Spill args/metadata to temp files above this many bytes. |
| `MCPBASH_TOOL_ENV_MODE` | `minimal` | Tool env isolation: `minimal`, `inherit`, or `allowlist`. |
| `MCPBASH_TOOL_ENV_ALLOWLIST` | (unset) | Extra env names when `MCPBASH_TOOL_ENV_MODE=allowlist`. |
| `MCPBASH_TOOL_ENV_INHERIT_ALLOW` | `false` | Must be `true` to allow `MCPBASH_TOOL_ENV_MODE=inherit`. |
| `MCPBASH_PROVIDER_ENV_MODE` | `isolate` | Provider env isolation (completion/resource providers): `isolate`, `inherit`, or `allowlist`. Prompts ignore this setting. |
| `MCPBASH_PROVIDER_ENV_ALLOWLIST` | (unset) | Extra env names when `MCPBASH_PROVIDER_ENV_MODE=allowlist`. |
| `MCPBASH_PROVIDER_ENV_INHERIT_ALLOW` | `false` | Must be `true` to allow `MCPBASH_PROVIDER_ENV_MODE=inherit`. |
| `MCPBASH_TOOL_ALLOWLIST` | (required) | Space/comma-separated tool names allowed to run (`*` to allow all). Empty by default (deny). |
| `MCPBASH_TOOL_ALLOW_DEFAULT` | `deny` | Set to `allow` to keep legacy allow-all behavior without an explicit allowlist. |
| `MCPBASH_FORCE_MINIMAL` | (unset) | Force minimal capability tier even when JSON tooling is present. |
| `MCPBASH_JSON_TOOL` | (auto-detect jq → gojq) | Explicit JSON tool selection: `jq`, `gojq`, or `none`. Default order is jq-first (Windows E2BIG mitigation). |
| `MCPBASH_JSON_TOOL_BIN` | (derived from tool) | Explicit path to JSON tool; infers `MCPBASH_JSON_TOOL` from basename if unset and treats unknown names as jq-compatible (behavior may differ if flags differ). |
| `MCPBASH_ALLOW_JSON_TOOL_OVERRIDE_FOR_ROOT` | `false` | Allow `MCPBASH_JSON_TOOL{,_BIN}` overrides when running as root. |
| `MCPBASH_COMPAT_BATCHES` | (unset) | Enable legacy batch request support (auto-enabled when protocol is `2025-03-26`; use only for out-of-spec clients on newer protocols). |
| `MCPBASH_DEBUG_PAYLOADS` | (unset) | Write full message payloads to `${TMPDIR}/mcpbash.state.*`. |
| `MCPBASH_DEBUG_ERRORS` | `false` | When `true`, include tool diagnostics (exit code, stderr tail, trace line) in outputSchema validation errors. |
| `MCPBASH_DEBUG_LOG` | (unset) | Override the per-tool debug log path; when unset, tools get a per-invocation file under the log/state dir. |
| `MCPBASH_PRESERVE_STATE` | (unset) | Preserve state dir after exit (useful with `MCPBASH_DEBUG_PAYLOADS`; includes per-request `stderr.*.log` worker captures). |
| `MCPBASH_REMOTE_TOKEN` | (unset) | Shared secret for proxied deployments (minimum 32 characters). |
| `MCPBASH_REMOTE_TOKEN_KEY` | `mcpbash/remoteToken` | JSON path for token lookup. |
| `MCPBASH_REMOTE_TOKEN_FALLBACK_KEY` | `remoteToken` | Alternate JSON path for token lookup. |
| `MCPBASH_REMOTE_TOKEN_MAX_FAILURES_PER_MIN` | `10` | Max failed remote-token attempts per minute before throttling responses. |
| `MCPBASH_HTTPS_ALLOW_HOSTS` / `MCPBASH_HTTPS_DENY_HOSTS` | (unset) | HTTPS provider host allow/deny lists; private/loopback always blocked. **Allow list is required** unless `MCPBASH_HTTPS_ALLOW_ALL=true`. HTTPS fetches use curl and pin resolved IPs via `--resolve` (DNS rebinding mitigation). |
| `MCPBASH_HTTPS_ALLOW_ALL` | `false` | Explicitly allow all public HTTPS hosts (unsafe; prefer `MCPBASH_HTTPS_ALLOW_HOSTS`). |
| `MCPBASH_HTTPS_TIMEOUT` | `15` (cap ≤60s) | HTTPS provider timeout. |
| `MCPBASH_HTTPS_MAX_BYTES` | `10485760` (cap ≤20MB) | HTTPS payload size guard. |
| `MCPBASH_ENABLE_GIT_PROVIDER` | `false` | Enable Git resource provider (`git+https://` URIs). |
| `MCPBASH_GIT_ALLOW_HOSTS` / `MCPBASH_GIT_DENY_HOSTS` | (unset) | Allow/deny lists; private/loopback always blocked. Allow list (or `MCPBASH_GIT_ALLOW_ALL=true`) is required when the git provider is enabled. |
| `MCPBASH_GIT_ALLOW_ALL` | `false` | Explicitly allow all git hosts (unsafe; prefer `MCPBASH_GIT_ALLOW_HOSTS`). |
| `MCPBASH_GIT_TIMEOUT` | `30` (cap ≤60s) | Git provider timeout (seconds). |
| `MCPBASH_GIT_MAX_KB` | `51200` (cap ≤1048576) | Git repository size guard (KB). |
| `MCPBASH_CORRUPTION_WINDOW` | `60` | Stdout corruption tracking window (seconds). |
| `MCPBASH_CORRUPTION_THRESHOLD` | `3` | Corruption events allowed within the window before exit. |
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

## Internal Runtime State (do not override)

Examples: `MCPBASH_STATE_DIR`, `MCPBASH_LOCK_ROOT`, `MCPBASH_TMP_ROOT`, `MCPBASH_STDOUT_LOCK_NAME`, `MCPBASH_INITIALIZED`, `MCPBASH_ROOTS_*`, `MCPBASH_CLIENT_SUPPORTS_*`, `MCPBASH_PROGRESS_FLUSHER_PID`, `MCPBASH_RESOURCE_POLL_PID`, `MCPBASH_NEXT_OUTGOING_ID`, `MCPBASH_HANDLER_OUTPUT`. These are set by the runtime to coordinate sourced scripts and are not user-facing.

## Test/Scaffold/Installer Helpers

| Variable | Default | Notes |
|----------|---------|-------|
| `MCPBASH_RUN_TOOL_SOURCE_SERVER_ENV` | (unset) | When `true` or `1`, `mcp-bash run-tool` implicitly sources `server.d/env.sh` before tool execution (equivalent to `--with-server-env` flag). Useful in CI pipelines where all `run-tool` invocations should use server environment. |

Examples: `MCPBASH_BASE_TAR` / `MCPBASH_BASE_TAR_META` / `MCPBASH_BASE_TAR_KEY`, `MCPBASH_STAGING_TAR`, `MCPBASH_TEST_ROOT`, `MCPBASH_INTEGRATION_TMP`, `MCPBASH_RUN_SDK_TYPESCRIPT`, `MCPBASH_LOG_JSON_TOOL` (suite logging), integration runner controls (`MCPBASH_INTEGRATION_ONLY`, `MCPBASH_INTEGRATION_SKIP`, `MCPBASH_INTEGRATION_TEST_TIMEOUT_SECONDS`), installer overrides (`MCPBASH_INSTALL_REPO_URL`). Keep these scoped to testing or packaging workflows. 
