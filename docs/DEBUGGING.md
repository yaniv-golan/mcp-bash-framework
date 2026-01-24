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

## Debug File (Persistent Debug Mode)

Instead of setting `MCPBASH_LOG_LEVEL=debug` each time, create a `.debug` marker file:

```bash
touch server.d/.debug    # Enable debug logging
rm server.d/.debug       # Disable debug logging
```

Only the file's existence matters—contents are ignored. An empty file works fine.

**Precedence**: Environment variable always wins. If `MCPBASH_LOG_LEVEL` is set, the `.debug` file is ignored.

**Tip**: Add `server.d/.debug` to your `.gitignore` to prevent accidental commits:
```
# Debug marker file (enables MCPBASH_LOG_LEVEL=debug)
server.d/.debug
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
| `MCPBASH_DEBUG_ERRORS` | `false` | Include tool diagnostics (exit code, stderr tail, trace line) in outputSchema validation errors |
| `MCPBASH_DEBUG_LOG` | (unset) | Per-tool debug log path (auto-set per invocation); SDK `mcp_debug` appends to it |
| `MCPBASH_LOG_LEVEL` | `info` | Set to `debug` for verbose stderr logging |
| `MCPBASH_LOG_VERBOSE` | (unset) | Set to `true` to include file paths in logs |
| `MCPBASH_TOOL_STDERR_CAPTURE` | `true` | Include a bounded stderr tail in tool error responses (`error.data._meta.stderr` / `stderrTail`) |
| `MCPBASH_TOOL_STDERR_TAIL_LIMIT` | `4096` | Max bytes of stderr tail to attach to responses |
| `MCPBASH_TOOL_TIMEOUT_CAPTURE` | `true` | Include timeout exit code and stderr tail (when available) in timeout errors |
| `MCPBASH_TRACE_TOOLS` | `false` | Enable `set -x` tracing for shell tools; traces go to per-invocation logs under `MCPBASH_STATE_DIR`. SDK helpers suppress xtrace around secret-bearing args/_meta payload expansions. |
| `MCPBASH_TRACE_PS4` | `+ ${BASH_SOURCE[0]##*/}:${LINENO}: ` | Override PS4 used for traces (timestamps or custom format) |
| `MCPBASH_TRACE_MAX_BYTES` | `1048576` | Max bytes to retain per trace log (truncated to tail when exceeded) |
| `MCPBASH_DEBUG` | `false` | Enable debug EXIT trap that logs exit location and call stack on non-zero exits; helps diagnose `set -e` failures |
| `MCPBASH_DEBUG_ALL_EXITS` | `false` | With `MCPBASH_DEBUG=true`, log all exits (not just failures) |
| `MCPBASH_INTEGRATION_DEBUG_FAILED` | `false` | Re-run failed integration tests with `bash -x` tracing |
| `MCPBASH_CI_MODE` | `false` | Opt-in CI defaults: safe `TMP_ROOT`, log dir, keep logs, timestamps; emits failure summaries and env snapshot; GH annotations when `GITHUB_ACTIONS=true` |
| `MCPBASH_CI_VERBOSE` | `false` | With CI mode, start at debug log level instead of info |
| `MCPBASH_LOG_DIR` | (unset) | Log directory; CI mode sets a default when unset |
| `MCPBASH_KEEP_LOGS` | `false` | Preserve state/log files on exit (`true` by default in CI mode) |
| `MCPBASH_LOG_TIMESTAMP` | `false` | Prefix log messages with UTC timestamp (`true` by default in CI mode) |

For file-based checkpoints inside tools, use the SDK helper:

```bash
mcp_debug "checkpoint: starting validation"
```

## Client Identity in Debug Mode

When `MCPBASH_LOG_LEVEL=debug`, the server logs the connecting client's identity at initialize:

```
[mcp.lifecycle] Client: claude-ai/0.1.0 pid=12345
```

This helps identify which mcp-bash process serves which client when multiple instances are running (common with Claude Desktop, which can spawn many server processes).

## CI Mode Notes
- Enable with `MCPBASH_CI_MODE=true` to get CI-friendly defaults: tmp root under `RUNNER_TEMP`/`$GITHUB_WORKSPACE/.mcpbash-tmp`/`TMPDIR`, default log dir, keep-logs, and timestamped log messages.
- CI mode writes `failure-summary.jsonl` (per-tool summaries: exit code, timeout flag, stderr tail, trace line, hashed args, counts) and a one-time `env-snapshot.json` (bash version, OS, cwd, PATH first/last/count, `pathBytes`/`envBytes` in bytes, `jsonTool`/`jsonToolBin`) under the log dir. The snapshot records counts/sizes only—no env contents are dumped.
- On GitHub Actions, if tracing provides a file:line, CI mode emits `::error` annotations for tool failures/timeouts.
- Integration/conformance tests may also write **failure bundles** under `${MCPBASH_LOG_DIR}/failure-bundles/` containing `requests*.ndjson`, `responses*.ndjson`, and relevant `progress.*.ndjson`/`logs.*.ndjson` stream files to make Windows CI failures diagnosable from artifacts.
- Background workers start lazily: resource subscription polling begins after the first `resources/subscribe`, and the progress flusher starts only when live progress is enabled or a feature (like elicitation) requires it.

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

## Common Schema Errors

This section documents schema violations that pass basic validation but fail with strict MCP clients (Cursor, Claude Desktop, MCP Inspector).

### "expected object, received string" for icons

**Symptom**: MCP Inspector or Cursor fails with:
```
serverInfo.icons[0] - expected object, received string
```

**Cause**: The `icons` field uses plain strings instead of objects with `src` property.

**Wrong**:
```json
{
  "icons": ["path/to/icon.svg"]
}
```

**Correct**:
```json
{
  "icons": [{"src": "path/to/icon.svg"}]
}
```

This applies to:
- `server.d/server.meta.json` (server icons)
- `tools/*/tool.meta.json` (tool icons)
- `prompts/*/prompt.meta.json` (prompt icons)
- `resources/*/resource.meta.json` (resource icons)

**Fix**: Run `mcp-bash validate --strict` which now validates icons format.

### Strict client validation failures

If raw stdio works but MCP Inspector/Cursor/Claude Desktop fails:

1. The response likely violates the MCP schema in a way basic validation doesn't catch
2. Run `mcp-bash validate --strict` first
3. Run `mcp-bash validate --inspector` for full MCP Inspector validation
4. Or test manually with Inspector CLI:
   ```bash
   npx @modelcontextprotocol/inspector --cli --transport stdio -- \
     ./bin/mcp-bash --method tools/list
   ```
5. Inspector CLI gives the exact schema validation error with field path

### Missing or invalid required fields

Common issues:
- Tool missing `name` or `description`
- Resource missing `uri` or `uriTemplate` (one is required; they are mutually exclusive)
- Invalid `inputSchema` (must have `type` or `properties`)

Run `mcp-bash validate` to catch these before testing with clients.

## Troubleshooting Flowchart

When a server works from CLI but fails in MCP clients, follow this diagnostic path:

```
1. Does raw stdio work?
   $ echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ./bin/mcp-bash

   No  -> Check: MCPBASH_PROJECT_ROOT, file permissions, framework install
   Yes -> Continue to step 2

2. Does basic validation pass?
   $ mcp-bash validate --strict

   No  -> Fix validation errors (icons format, missing fields, etc.)
   Yes -> Continue to step 3

3. Does MCP Inspector validation pass?
   $ mcp-bash validate --inspector

   No  -> Inspector shows exact schema violation - fix it
   Yes -> Continue to step 4

4. Still failing in Cursor/Claude Desktop?
   Check:
   - macOS quarantine: xattr -r -d com.apple.quarantine ./
   - PATH issues: use absolute paths or wrapper script
   - TCC permissions: grant Full Disk Access if in protected folder
   - Use login-aware wrapper: mcp-bash config --wrapper-env > wrapper.sh
```

## Zombie/Orphaned MCP Server Processes

### Symptoms

- Multiple `mcp-bash` processes accumulating over time
- Processes with high uptime that appear to be doing nothing
- High memory usage from accumulated server instances

### Causes

MCP clients (like Claude Desktop) may disconnect without sending proper `shutdown`/`exit` JSON-RPC messages. When this happens, mcp-bash servers can remain running indefinitely waiting for input that never arrives.

### Built-in Mitigations (v0.14.0+)

mcp-bash includes automatic defenses against zombie processes:

1. **Idle Timeout** (enabled by default): Servers exit after 1 hour of no client activity
2. **Orphan Detection** (enabled on Unix): Servers exit if their parent process dies

### Manual Cleanup

If you have accumulated zombie processes, you can clean them up:

```bash
# List all mcp-bash processes
ps aux | grep mcp-bash

# Kill all mcp-bash processes (use with caution)
pkill -f mcp-bash

# Kill processes older than 1 day with PPID=1 (orphaned)
ps -eo pid,ppid,etime,args | grep mcp-bash | awk '$2==1 && $3 ~ /-/ {print $1}' | xargs kill
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `MCPBASH_IDLE_TIMEOUT` | `3600` | Seconds before idle exit (0 = disabled) |
| `MCPBASH_IDLE_TIMEOUT_ENABLED` | `true` | Master switch for idle timeout |
| `MCPBASH_ORPHAN_CHECK_ENABLED` | `true` (Unix), `false` (Windows/CI) | Enable parent-death detection |
| `MCPBASH_ORPHAN_CHECK_INTERVAL` | `30` | Seconds between orphan checks |

### Disabling Mitigations

For long-running embedded scenarios where the server intentionally runs without client interaction:

```bash
export MCPBASH_IDLE_TIMEOUT=0
export MCPBASH_ORPHAN_CHECK_ENABLED=false
```

## See Also

- [LOGGING.md](LOGGING.md) - General logging configuration
- [INSPECTOR.md](INSPECTOR.md) - MCP Inspector recipes + strict-client pitfalls
- [BEST-PRACTICES.md](BEST-PRACTICES.md) - Best practices guide
