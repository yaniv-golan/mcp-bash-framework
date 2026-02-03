# Logging

## Logging Basics

- Set level with `MCPBASH_LOG_LEVEL` (`debug`, `info`, `notice`, `warning`, `error`, ...). Default is `info`.
- Boolean values `true`/`1` are normalized to `debug`, and `false`/`0` to `info`. This supports UI toggles that map boolean debug settings to `MCPBASH_LOG_LEVEL`.
- The `.debug` file in `server.d/` only takes effect if `MCPBASH_LOG_LEVEL` is unset. If an MCP host passes `MCPBASH_LOG_LEVEL` via manifest (even as `false`), the file is ignored. Use the host's debug toggle instead.
- Debug logs emit only when `MCPBASH_LOG_LEVEL=debug`. Warning/error logs always emit regardless of level.
- Argument values are never logged; debug traces focus on flow (method, ids, counts, byte sizes).
- Startup diagnostics (transport, cwd, project root, JSON tool) are written to stderr only when `MCPBASH_LOG_STARTUP=true` or `MCPBASH_LOG_VERBOSE=true` while running over the stdio transport so stdout stays JSON-only for clients and Inspector.
- Tool stderr capture is opt-in configurable: `MCPBASH_TOOL_STDERR_CAPTURE` (`true`/`false`), `MCPBASH_TOOL_STDERR_TAIL_LIMIT` (bytes, default 4096), and `MCPBASH_TOOL_TIMEOUT_CAPTURE` for timeouts.
- Tool debug logs: tools receive `MCPBASH_DEBUG_LOG` (per-invocation file path); use the SDK `mcp_debug` helper to append checkpoints.
- OutputSchema errors can include tool diagnostics when `MCPBASH_DEBUG_ERRORS=true`.
- Tool tracing is opt-in: set `MCPBASH_TRACE_TOOLS=true` to enable `set -x` for shell tools, with `PS4` override via `MCPBASH_TRACE_PS4` and trace size cap via `MCPBASH_TRACE_MAX_BYTES` (default 1MB). SDK helpers suppress xtrace around secret-bearing args/_meta payload expansions, but tools can still leak secrets if they print values explicitly.
- CI mode (`MCPBASH_CI_MODE=true`) sets safe defaults for tmp root/log dir, keeps logs, enables timestamps (`MCPBASH_LOG_TIMESTAMP=true`), and can start at debug with `MCPBASH_CI_VERBOSE=true`. CI mode also writes `failure-summary.jsonl` and `env-snapshot.json` (PATH/env byte sizes + selected JSON tool metadata, no env dump) under the log dir and emits GitHub Actions `::error` annotations when tracing provides file/line.

## Verbose Mode (paths + script output)

Enable to surface paths and manual-registration output:

```bash
export MCPBASH_LOG_VERBOSE=true
# Optional for debug traces:
export MCPBASH_LOG_LEVEL=debug
```

Behavior:
- Debug logs: still require `MCPBASH_LOG_LEVEL=debug`; verbose adds path detail (tool path, resource URIs, etc.).
- Warning/error logs: visible at any level; verbose determines whether paths/script output are shown. Without verbose, paths and script output are redacted.

### Security Warning

Verbose mode exposes file paths, usernames (via paths), cache locations, and manual registration script output. Use only in trusted environments. Even in verbose mode, tool/prompt argument **values** and **keys** are never logged.

## Redaction Rules

- Paths/URIs: redacted by default; shown only if `MCPBASH_LOG_VERBOSE=true`.
- Manual registration script output: redacted by default; shown only if verbose is enabled.
- Argument values and keys: never logged (all levels, verbose or not).
- Env vars, file contents: never logged.

## Debug Coverage (highlights)

- Core: dispatch and handler responses (`lib/core.sh`).
- Lifecycle: initialize/initialized/shutdown events, client identity (name/version/pid) at connect (`handlers/lifecycle.sh`).
- Tools: invoke/complete traces, registry refresh counts, tools/list handler (`lib/tools.sh`, `handlers/tools.sh`).
- Prompts: list/get traces, registry refresh counts, prompts/list handler (`lib/prompts.sh`, `handlers/prompts.sh`).
- Runtime: JSON tool detection prints tool path only when verbose is enabled (`lib/runtime.sh`).

## Quick Checks

- No verbose: paths/URIs/script output should be redacted in warning/error logs; debug logs emit only at `MCPBASH_LOG_LEVEL=debug` and omit paths.
- With verbose + debug: debug logs include paths; warning/error logs include paths and script output.
- With verbose at info: warning/error logs include paths/script output; debug logs remain suppressed unless `MCPBASH_LOG_LEVEL=debug`.
