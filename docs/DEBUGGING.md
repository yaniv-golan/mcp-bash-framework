# Debugging with MCP Inspector

This guide explains how to debug mcp-bash servers and analyze the exact JSON-RPC messages exchanged between client and server.

## Quick Start

```bash
mcp-bash debug
```

That's it. The debug subcommand:
- Enables full payload logging
- Preserves state directory after exit
- Prints the log location immediately at startup

Output:
```
mcp-bash debug: logging to /tmp/mcpbash.debug.12345/payload.debug.log
```

## Claude Desktop on macOS (PATH + quarantine)

Claude Desktop often execs servers directly (no login shell), so `~/.zshrc`/`~/.bash_profile` are skipped and PATH/env customizations (nvm/pyenv/uv/rbenv, etc.) are missing. Common symptoms: `ENOENT` / `command not found`, `transport closed unexpectedly`, missing env vars. Location can matter on macOS: Desktop/Documents/Downloads are TCC-protected and Downloads is frequently quarantined.

Fixes:
- Use absolute paths to runtimes (e.g., `/opt/homebrew/bin/node`) and set required vars in the MCP config `env` block.
- Or generate a login-aware wrapper that sources your shell profile before exec:
  ```bash
  mcp-bash config --project-root /path/to/project --wrapper-env > /path/to/project/mcp-bash.sh
  chmod +x /path/to/project/mcp-bash.sh
  ```
  Point Claude Desktop at that wrapper as the `command`.
- macOS quarantine can silently block downloaded binaries/scripts. Browser/DMG/AirDrop downloads are commonly quarantined; CLI fetches (curl/wget/git) often are not. Clear quarantine, then restart Claude Desktop:
  ```bash
  xattr -r -d com.apple.quarantine ~/.local/share/mcp-bash
  xattr -r -d com.apple.quarantine /path/to/project
  ```
  Helper: `scripts/macos-dequarantine.sh [path]` clears quarantine for the repo or a custom path. `xattr -cr` removes all extended attributes—only use it on trusted paths.
- macOS folder permissions: Desktop/Documents/Downloads and similar are TCC-protected. If your server or data lives there, grant Claude Desktop “Full Disk Access” and “Files and Folders” in System Settings (or relocate to a neutral folder) to avoid `Operation not permitted` or silent exits.
- Diagnostics: To see Gatekeeper/TCC blocks while launching a server, run:
  ```bash
  log stream --predicate 'process == "taskgated" OR process == "tccd" OR process == "syspolicyd"' --info
  ```

## Analyzing Debug Logs

Use the provided analysis script:

```bash
# Pretty-print all messages (default)
scripts/analyze-debug-log /tmp/mcpbash.debug.12345/payload.debug.log

# Compact view - one line per message
scripts/analyze-debug-log debug.log --compact

# Show only incoming requests
scripts/analyze-debug-log debug.log --requests

# Show only outgoing responses
scripts/analyze-debug-log debug.log --responses

# Output as JSON array (for further processing)
scripts/analyze-debug-log debug.log --json
```

## Using with MCP Inspector

Configure MCP Inspector to use the debug subcommand:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/path/to/mcp-bash/bin/mcp-bash",
      "args": ["debug"],
      "env": {
        "MCPBASH_PROJECT_ROOT": "/path/to/my-project"
      }
    }
  }
}
```

The log location is printed to stderr at startup, so you can see it in Inspector's server output.

For a ready-to-run Inspector invocation that sets `MCPBASH_PROJECT_ROOT` for the current project, run:

```bash
mcp-bash config --inspector
```

## Debug Log Format

The log file `payload.debug.log` is pipe-delimited:

```
timestamp|category|key|status|payload
```

| Field | Description |
|-------|-------------|
| `timestamp` | Unix epoch seconds |
| `category` | `request` (incoming), `response` (outgoing), `handler`, `worker` |
| `key` | Request ID or `-` |
| `status` | `recv`, `ok`, `error`, `cancelled`, etc. |
| `payload` | JSON-RPC message (newlines escaped as `\n`) |

Example entries:
```
1732900000|request|-|recv|{"jsonrpc":"2.0","id":"1","method":"initialize","params":{}}
1732900000|response|1|ok|{"jsonrpc":"2.0","id":"1","result":{"protocolVersion":"2025-11-25",...}}
1732900001|request|-|recv|{"jsonrpc":"2.0","method":"notifications/initialized"}
```

## Manual jq Commands

If you prefer working with jq directly:

```bash
# Pretty-print all payloads
cut -d'|' -f5 payload.debug.log | while read -r line; do
  echo "$line" | jq .
done

# List methods called
cut -d'|' -f5 payload.debug.log | jq -r '.method // empty' 2>/dev/null | sort | uniq -c

# Show only incoming requests
grep '|request|' payload.debug.log | cut -d'|' -f5 | jq .

# Show only outgoing responses
grep '|response|' payload.debug.log | cut -d'|' -f5 | jq .

# Find errors
grep -E '\|error\||\\"error\\":' payload.debug.log | cut -d'|' -f5 | jq .
```

## Environment Variables (Advanced)

For manual control without the `debug` subcommand:

| Variable | Default | Description |
|----------|---------|-------------|
| `MCPBASH_DEBUG_PAYLOADS` | (unset) | Set to `true` to log all JSON-RPC messages |
| `MCPBASH_PRESERVE_STATE` | (unset) | Set to `true` to keep state directory after exit |
| `MCPBASH_LOG_LEVEL` | `info` | Set to `debug` for verbose stderr logging |
| `MCPBASH_LOG_VERBOSE` | (unset) | Set to `true` to include file paths in logs |
| `MCPBASH_TOOL_STDERR_CAPTURE` | `true` | Include a bounded stderr tail in tool error responses (`error.data._meta.stderr` / `stderrTail`) |
| `MCPBASH_TOOL_STDERR_TAIL_LIMIT` | `4096` | Max bytes of stderr tail to attach to responses |
| `MCPBASH_TOOL_TIMEOUT_CAPTURE` | `true` | Include timeout exit code and stderr tail (when available) in timeout errors |
| `MCPBASH_TRACE_TOOLS` | `false` | Enable `set -x` tracing for shell tools; traces go to per-invocation logs under `MCPBASH_STATE_DIR` |
| `MCPBASH_TRACE_PS4` | `+ ${BASH_SOURCE[0]##*/}:${LINENO}: ` | Override PS4 used for traces (timestamps or custom format) |
| `MCPBASH_TRACE_MAX_BYTES` | `1048576` | Max bytes to retain per trace log (truncated to tail when exceeded) |
| `MCPBASH_CI_MODE` | `false` | Opt-in CI defaults: safe `TMP_ROOT`, log dir, keep logs, timestamps; emits failure summaries and env snapshot; GH annotations when `GITHUB_ACTIONS=true` |
| `MCPBASH_CI_VERBOSE` | `false` | With CI mode, start at debug log level instead of info |
| `MCPBASH_LOG_DIR` | (unset) | Log directory; CI mode sets a default when unset |
| `MCPBASH_KEEP_LOGS` | `false` | Preserve state/log files on exit (`true` by default in CI mode) |
| `MCPBASH_LOG_TIMESTAMP` | `false` | Prefix log messages with UTC timestamp (`true` by default in CI mode) |

## CI Mode Notes
- Enable with `MCPBASH_CI_MODE=true` to get CI-friendly defaults: tmp root under `RUNNER_TEMP`/`$GITHUB_WORKSPACE/.mcpbash-tmp`/`TMPDIR`, default log dir, keep-logs, and timestamped log messages.
- CI mode writes `failure-summary.jsonl` (per-tool summaries: exit code, timeout flag, stderr tail, trace line, hashed args, counts) and a one-time `env-snapshot.json` (bash version, OS, cwd, PATH first/last/count, `pathBytes`/`envBytes` in bytes, `jsonTool`/`jsonToolBin`) under the log dir. The snapshot records counts/sizes only—no env contents are dumped.
- On GitHub Actions, if tracing provides a file:line, CI mode emits `::error` annotations for tool failures/timeouts.

Example:
```bash
export MCPBASH_DEBUG_PAYLOADS=true
export MCPBASH_PRESERVE_STATE=true
./bin/mcp-bash
```

## Security Considerations

Debug logs contain **all message payloads**, including:
- Tool arguments and results
- Resource contents
- Prompt text
- Any data exchanged with the client

**Do not enable debug logging in production.** Clean up after debugging:
```bash
rm -rf ${TMPDIR:-/tmp}/mcpbash.debug.*
```

## See Also

- [LOGGING.md](LOGGING.md) - General logging configuration
- [BEST-PRACTICES.md](BEST-PRACTICES.md) - Debugging flowchart
