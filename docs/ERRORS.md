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
- Server errors (internal failures, cancellation)
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
| Tool not found | Protocol (`-32602`) | Invalid tool name (entity not found) |
| Date format invalid | Tool Execution (`isError: true`) | LLM can retry with correct format |
| Value out of range | Tool Execution (`isError: true`) | LLM can adjust the value |
| File path outside roots | Tool Execution (`isError: true`) | LLM can choose allowed path |
| Tool timeout | Tool Execution (`isError: true`) | LLM can adjust parameters; see [Timeout Strategy Guide](BEST-PRACTICES.md#timeout-strategy-guide) |
| API rate limited | Tool Execution (`isError: true`) | LLM can retry later |

### SDK Support

Use the SDK helpers to return the appropriate error type:

```bash
# Tool Execution Error (LLM can self-correct)
# Use mcp_error for convenience with consistent schema:
mcp_error "validation_error" "Date must be in the future" \
  --hint "Use a date after today" \
  --data '{"received": "2020-01-01"}'

# Or use mcp_result_error directly with a JSON object:
mcp_result_error "$(mcp_json_obj \
  type "validation_error" \
  message "Date must be in the future" \
  received "2020-01-01"
)"

# For missing/malformed required parameters, use protocol error instead:
mcp_fail_invalid_args "date parameter is required"
```

**Recommended error types** for consistency:

| Type | Use case |
|------|----------|
| `not_found` | Entity doesn't exist |
| `validation_error` | Input fails validation |
| `invalid_json` | JSON parsing failed |
| `permission_denied` | Access not allowed |
| `file_error` | File system operation failed |
| `network_error` | Network request failed |
| `redirect` | URL redirected to a different location (see `.error.location` for target); returned by HTTPS provider on 3xx responses |
| `timeout` | Operation timed out |
| `cli_error` | External command failed |
| `internal_error` | Unexpected/fallback error |
| `path_not_found` | `--array-path` points to missing key (truncation) |
| `invalid_array_path` | Path exists but is not an array (truncation) |
| `invalid_path_syntax` | Malformed jq path (truncation) |
| `output_too_large` | Response too large even with empty array (truncation) |

#### Structured response envelope helpers

For tools returning structured data with consistent `{success, result}` or `{success, error}` envelopes:

```bash
# Success response: isError=false, structuredContent.success=true
mcp_result_success '{"items": [...], "count": 42}'

# Error response: isError=true, structuredContent.success=false
mcp_result_error '{"type": "not_found", "path": "/missing/file"}'
```

These helpers set the appropriate `isError` flag automatically and populate both `content[].text` (human-readable summary) and `structuredContent` (machine-readable envelope). See [BEST-PRACTICES.md §4.7](BEST-PRACTICES.md#47-building-calltoolresult-responses) for full documentation.

For validation that happens early in a tool (before doing real work), prefer returning `isError: true` so the LLM learns from the feedback.

---

## General Error Handling

- Tool failures return `isError=true` with `_meta.exitCode` and captured stderr; error responses include `error.data.exitCode`, `error.data.stderrTail` (bounded), and `error.data.traceLine` when tracing is enabled, with the same `_meta.stderr` for compatibility. Disable capture with `MCPBASH_TOOL_STDERR_CAPTURE=false`; adjust the tail cap with `MCPBASH_TOOL_STDERR_TAIL_LIMIT` (default 4096 bytes).
- **Timeouts** return `isError=true` with `structuredContent.error` containing `type: "timeout"`, the timeout `reason` (`fixed`, `idle`, or `max_exceeded`), `timeoutSecs`, and `exitCode`. When progress-aware timeout is enabled, `progressExtendsTimeout` and `maxTimeoutSecs` are also included. If `timeoutHint` is configured in `tool.meta.json`, the `hint` field is included in `structuredContent.error` and a "Suggestion:" is appended to the error message.
- Cancellation surfaces as JSON-RPC error (`-32001`) as it is client-initiated and not actionable by the LLM.
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
| `-32601` | Unknown or disallowed method (`notifications/message` from client, missing handler) | `lib/core.sh`, `handlers/*` |
| `-32602` | Invalid params (unsupported protocol version, invalid cursor/log level, missing/invalid remote token) | `handlers/lifecycle.sh`, `handlers/completion.sh`, `handlers/logging.sh`, `lib/auth.sh`, registry cursors |
| `-32603` | Internal errors (empty handler response, registry size/parse failures, tool output/stderr over limits, provider failures); also used for tool timeouts | `lib/core.sh`, `lib/tools.sh`, `lib/resources.sh`, `lib/prompts.sh` |
| `-32001` | Tool cancelled (SIGTERM/INT from client) | `lib/tools.sh` |
| `-32000` | Server not initialized (`initialize` not completed) | `lib/core.sh` |
| `-32002` | Resource not found (`resources/read`) | `lib/resources.sh` |
| `-32003` | Server shutting down (rejecting new work) | `lib/core.sh` |
| `-32005` | `exit` called before `shutdown` was requested | `handlers/lifecycle.sh` |

Size guardrails: `mcp_core_guard_response_size` rejects oversized responses with `-32603` (tool/resource reads use `MCPBASH_MAX_TOOL_OUTPUT_SIZE`, default 10MB; registry/list payloads use `MCPBASH_REGISTRY_MAX_BYTES`, default 100MB) and does not return partial content.

## Resource provider exit codes
- `file.sh`: `2` outside allowed roots → `-32603`; `3` missing file → `-32002`.
- `git.sh`: `4` invalid URI or missing git → `-32602`; `5` clone/fetch failure → `-32603`.
- `https.sh`: `4` invalid URI or missing curl → `-32602`; `5` network/timeout → `-32603`; `6` payload exceeds `MCPBASH_HTTPS_MAX_BYTES` → `-32603`.
- Any other provider exit code maps to `-32603` with stderr text when available.

## Troubleshooting Quick Hits
- **Unsupported protocol (`-32602`)**: Client requested an older MCP version. Update the client or request `2025-11-25`/`2025-06-18`/`2025-03-26`/`2024-11-05`.
- **Invalid cursor (`-32602`)**: Drop the cursor to restart pagination; ensure clients do not cache cursors across registry refreshes.
- **Tool timed out (`isError: true`, `structuredContent.error.type: "timeout"`)**: The tool exceeded its time limit. Check `structuredContent.error.reason` for context:
  - `"fixed"` – Static timeout elapsed (progress-aware timeout disabled).
  - `"idle"` – Progress-aware timeout enabled, but no activity detected (pattern match or progress emission) within the idle window.
  - `"max_exceeded"` – Progress-aware timeout enabled, tool showed activity but hit the hard cap (`maxTimeoutSecs`).

  Fix: Reduce workload, raise `timeoutSecs` in `<tool>.meta.json`, enable `progressExtendsTimeout` for long-running tools that emit progress, or adjust `MCPBASH_MAX_TIMEOUT_SECS` for the hard cap. Add `timeoutHint` to provide actionable guidance in the error message. See [Timeout Strategy Guide](BEST-PRACTICES.md#timeout-strategy-guide) for detailed configuration guidance.
- **Prompt render failed (`-32603`)**: Ensure the prompt file exists and is readable.
- **Resource/provider failures (`-32603`, message includes provider detail such as "Unable to read resource")**: Confirm the provider is supported (`file`, `git`, `https`), URI is valid, and payload size is within `MCPBASH_MAX_RESOURCE_BYTES`.
- **Minimal mode responses (`-32601`)**: Ensure `jq`/`gojq` is available or unset `MCPBASH_FORCE_MINIMAL` to enable tools/resources/prompts.
- **jq parse error in tool output**: Often caused by external CLI failures producing empty stdout. Using `2>/dev/null` hides stderr but doesn't prevent empty output—add `|| echo '{}'` fallback. See [BEST-PRACTICES.md § Calling external CLI tools](BEST-PRACTICES.md#calling-external-cli-tools).
- **mcp_result_success/mcp_result_error produces no output**: Ensure JSON tooling is available (jq/gojq); in minimal mode these helpers return degraded JSON output. Check `MCPBASH_MODE` environment variable.
- **mcp_is_valid_json rejects valid-looking JSON**: The helper validates single JSON values only; arrays with multiple root objects or trailing content are rejected. Use `jq -e . >/dev/null 2>&1` for lenient validation.
- **mcp_json_truncate not truncating**: Ensure the second argument (max_bytes) is a positive integer. Non-numeric values default to 102400 (100KB).

## Operational Safeguards

- Stdout corruption (multi-line payloads, non-UTF-8, write failures) is counted; exceeding `MCPBASH_CORRUPTION_THRESHOLD` within `MCPBASH_CORRUPTION_WINDOW` triggers a forced exit.
- Registry refresh enforces `MCPBASH_REGISTRY_MAX_BYTES`; exceeding the limit or encountering parse failures returns `-32603` and preserves the previous registry snapshot.
- Resource and tool payloads are capped by `MCPBASH_MAX_RESOURCE_BYTES` and `MCPBASH_MAX_TOOL_OUTPUT_SIZE`/`MCPBASH_MAX_TOOL_STDERR_SIZE`; breaches return `-32603` with a logged diagnostic.
- Minimal mode (missing JSON tooling or `MCPBASH_FORCE_MINIMAL=true`) accepts lifecycle, ping, and logging; other methods return `-32601` to avoid partial/ambiguous behavior.
