# Error Handling Guidelines

This document covers error handling patterns in mcp-bash, including the important distinction between **Protocol Errors** and **Tool Execution Errors**.

## Protocol Errors vs Tool Execution Errors

MCP distinguishes between two error types. Understanding this distinction is crucial for enabling LLM self-correction.

### Protocol Errors (JSON-RPC errors)

Protocol errors indicate fundamental issues with the request structure or server state. They are returned as JSON-RPC error objects with standard codes:

```json
{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Unknown tool: invalid_tool_name"}}
```

**When to use Protocol Errors:**
- Unknown or missing tool name
- Malformed request that fails schema validation
- Server errors (internal failures, timeouts, cancellation)
- Invalid cursors or pagination tokens

Protocol errors are **not actionable by the LLM** in most cases—the model cannot easily self-correct from "unknown tool" or "server error".

### Tool Execution Errors (isError: true)

Tool execution errors occur during tool execution and are returned as **successful results** with `isError: true`. These provide actionable feedback that LLMs can use to self-correct:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [{"type": "text", "text": "Invalid date: must be in the future (received: 2020-01-01)"}],
    "isError": true
  }
}
```

**When to use Tool Execution Errors:**
- Input validation failures the LLM could correct (bad date format, value out of range)
- Business logic errors (file not found, permission denied)
- API failures with actionable details
- Any error where the message helps the LLM retry with better inputs

### Choosing the Right Error Type

| Scenario | Error Type | Why |
|----------|------------|-----|
| Tool name missing | Protocol (`-32602`) | Request structure issue |
| Tool not found | Protocol (`-32601`) | Server-side resolution failure |
| Date format invalid | Tool Execution (`isError: true`) | LLM can retry with correct format |
| Value out of range | Tool Execution (`isError: true`) | LLM can adjust the value |
| File path outside roots | Tool Execution (`isError: true`) | LLM can choose allowed path |
| Tool timeout | Protocol (`-32603`) | Server-side resource limit |
| API rate limited | Tool Execution (`isError: true`) | LLM can retry later |

### SDK Support

Use the SDK helpers to return the appropriate error type:

```bash
# Tool Execution Error (LLM can self-correct)
# Return exit 0 but with error in output
mcp_emit_json '{"error": "Date must be in the future", "received": "2020-01-01"}'
# The framework wraps this with isError: true on non-zero exit

# OR use mcp_fail for structured errors that terminate the tool
mcp_fail -32602 "count must be between 1 and 100" '{"received": -5}'
```

For validation that happens early in a tool (before doing real work), prefer returning `isError: true` so the LLM learns from the feedback.

---

## General Error Handling

- Tool failures return `isError=true` with `_meta.exitCode` and captured stderr; error responses include `error.data.exitCode`, `error.data.stderrTail` (bounded), and `error.data.traceLine` when tracing is enabled, with the same `_meta.stderr` for compatibility. Disable capture with `MCPBASH_TOOL_STDERR_CAPTURE=false`; adjust the tail cap with `MCPBASH_TOOL_STDERR_TAIL_LIMIT` (default 4096 bytes).
- Timeouts and cancellation surface as JSON-RPC errors before tool output is returned; timeouts include `error.data.exitCode`, `error.data.stderrTail`, and `error.data.traceLine` (when tracing) when `MCPBASH_TOOL_TIMEOUT_CAPTURE` is enabled (default).
- Resource failures use JSON-RPC errors (no `isError` flag) consistent with the MCP spec: invalid cursors/params return `-32602`, provider failures and oversized payloads return `-32603`.
- Malformed tool output triggers a substitution with an error payload and a logged incident.
- Registry or discovery errors fall back to minimal capabilities while emitting `notifications/message` with severity `error`.
- Manual overrides should return well-formed JSON; otherwise auto-discovery resumes and issues `list_changed` notifications.

Example `resources/read` error payload:

```json
{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"Unable to read resource"}}
```

## JSON-RPC Error Codes

| Code | When emitted | Source |
|------|--------------|--------|
| `-32700` | Parse errors and invalid JSON normalization | `lib/core.sh` |
| `-32600` | Invalid request (missing method, batch arrays when disabled) | `lib/core.sh` |
| `-32601` | Unknown or disallowed method (`notifications/message` from client, missing handler, not found) | `lib/core.sh`, `handlers/*` |
| `-32602` | Invalid params (unsupported protocol version, invalid cursor/log level, missing/invalid remote token) | `handlers/lifecycle.sh`, `handlers/completion.sh`, `handlers/logging.sh`, `lib/auth.sh`, registry cursors |
| `-32603` | Internal errors (empty handler response, registry size/parse failures, tool output/stderr over limits, provider failures); also used for tool timeouts | `lib/core.sh`, `lib/tools.sh`, `lib/resources.sh`, `lib/prompts.sh` |
| `-32001` | Tool cancelled (SIGTERM/INT from client) | `lib/tools.sh` |
| `-32002` | Server not initialized (`initialize` not completed) | `lib/core.sh` |
| `-32003` | Server shutting down (rejecting new work) | `lib/core.sh` |
| `-32005` | `exit` called before `shutdown` was requested | `handlers/lifecycle.sh` |

Size guardrails: `mcp_core_guard_response_size` rejects oversized responses with `-32603` (tool/resource reads use `MCPBASH_MAX_TOOL_OUTPUT_SIZE`, default 10MB; registry/list payloads use `MCPBASH_REGISTRY_MAX_BYTES`, default 100MB) and does not return partial content.

## Resource provider exit codes
- `file.sh`: `2` outside allowed roots → `-32603`; `3` missing file → `-32601`.
- `git.sh`: `4` invalid URI or missing git → `-32602`; `5` clone/fetch failure → `-32603`.
- `https.sh`: `4` invalid URI or missing curl/wget → `-32602`; `5` network/timeout → `-32603`; `6` payload exceeds `MCPBASH_HTTPS_MAX_BYTES` → `-32603`.
- Any other provider exit code maps to `-32603` with stderr text when available.

## Troubleshooting Quick Hits
- **Unsupported protocol (`-32602`)**: Client requested an older MCP version. Update the client or request `2025-11-25`/`2025-06-18`/`2025-03-26`/`2024-11-05`.
- **Invalid cursor (`-32602`)**: Drop the cursor to restart pagination; ensure clients do not cache cursors across registry refreshes.
- **Tool timed out (`-32603`, message includes "timed out" or "killed")**: Reduce workload or raise `timeoutSecs` in `<tool>.meta.json`; defaults come from `MCPBASH_DEFAULT_TOOL_TIMEOUT`.
- **Resource/provider failures (`-32603`, message includes provider detail such as "Unable to read resource")**: Confirm the provider is supported (`file`, `git`, `https`), URI is valid, and payload size is within `MCPBASH_MAX_RESOURCE_BYTES`.
- **Minimal mode responses (`-32601`)**: Ensure `jq`/`gojq` is available or unset `MCPBASH_FORCE_MINIMAL` to enable tools/resources/prompts.

## Operational Safeguards

- Stdout corruption (multi-line payloads, non-UTF-8, write failures) is counted; exceeding `MCPBASH_CORRUPTION_THRESHOLD` within `MCPBASH_CORRUPTION_WINDOW` triggers a forced exit.
- Registry refresh enforces `MCPBASH_REGISTRY_MAX_BYTES`; exceeding the limit or encountering parse failures returns `-32603` and preserves the previous registry snapshot.
- Resource and tool payloads are capped by `MCPBASH_MAX_RESOURCE_BYTES` and `MCPBASH_MAX_TOOL_OUTPUT_SIZE`/`MCPBASH_MAX_TOOL_STDERR_SIZE`; breaches return `-32603` with a logged diagnostic.
- Minimal mode (missing JSON tooling or `MCPBASH_FORCE_MINIMAL=true`) accepts lifecycle, ping, and logging; other methods return `-32601` to avoid partial/ambiguous behavior.
