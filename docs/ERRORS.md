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

Tool execution errors occur during tool execution and are returned as **successful results** with `isError: true`. These provide actionable feedback that LLMs can use to self-correct. An error result from `mcp_fail --type` looks like this:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [{"type": "text", "text": "Date must be in the future\n\nHint: Use a date after today"}],
    "isError": true,
    "_meta": {
      "mcpbash/error": {
        "type": "invalid_args",
        "message": "Date must be in the future",
        "hint": "Use a date after today",
        "data": {"received": "2020-01-01"}
      }
    }
  }
}
```

The text block carries what the model reads (the message, plus the hint when there is one). Machine-readable details go in `_meta["mcpbash/error"]`; `hint` and `data` are left out when not given. An error result has no `structuredContent`, so it is never checked against the tool's `outputSchema`.

**When to use Tool Execution Errors:**
- Missing or invalid arguments the LLM could correct (required parameter missing, bad date format, value out of range)
- Business logic errors (file not found, permission denied)
- API failures with actionable details
- Any error where the message helps the LLM retry with better inputs

### Choosing the Right Error Type

| Scenario | Error Type | Why |
|----------|------------|-----|
| Tool name missing | Protocol (`-32602`) | Request structure issue |
| Tool not found | Protocol (`-32602`) | Invalid tool name (entity not found) |
| Required argument missing | Tool Execution (`isError: true`, type `invalid_args`): from `mcp_fail --type invalid_args` and, since 1.8, from the argument helpers (`mcp_args_require`, `mcp_args_int`, `mcp_args_bool`, `mcp_require_path`) and `mcp_download_safe_or_fail`, even inside `$(...)` | LLM can call again with the argument |
| Date format invalid | Tool Execution (`isError: true`) | LLM can retry with correct format |
| Value out of range | Tool Execution (`isError: true`) | LLM can adjust the value |
| File path outside roots | Tool Execution (`isError: true`) | LLM can choose allowed path |
| Tool denied by policy | Tool Execution (`isError: true`, type `policy_denied`) | LLM and user see the reason |
| Tool timeout | Tool Execution (`isError: true`) | LLM can adjust parameters; see [Timeout Strategy Guide](BEST-PRACTICES.md#timeout-strategy-guide) |
| API rate limited | Tool Execution (`isError: true`) | LLM can retry later |

### SDK Support

Return tool execution errors with `mcp_fail --type`. It returns the error result and **ends the tool**, so nothing after it runs. Inside `$(...)` (a helper whose output you capture, or `mcp_args_require` and the other argument helpers) the result still reaches the client through a side channel, but the non-zero exit only ends the substitution. **With `set -e` that ends the tool; without it, the script carries on with an empty value.** A tool that runs without `-e` (for example a CLI wrapper) must stop explicitly: `path="$(mcp_args_require '.path')" || exit 1`.

```bash
# Tool Execution Error (LLM can self-correct); ends the tool
mcp_fail --type invalid_args "Date must be in the future" \
  --hint "Use a date after today" \
  --data '{"received": "2020-01-01"}'

# Report a missing required parameter yourself so the model sees it:
mcp_fail --type invalid_args "date parameter is required" --hint "Pass date as YYYY-MM-DD"
```

`--data` must be valid JSON; with jq/gojq available, invalid data is dropped. To build the same result without ending the tool (for example to post-process it), call `mcp_tool_error_result TYPE MESSAGE [--hint TEXT] [--data JSON]`, which prints it and returns 0.

**Documented error types:**

| Type | Use case |
|------|----------|
| `invalid_args` | Arguments missing or invalid |
| `not_found` | Entity doesn't exist |
| `permission` | Access not allowed |
| `policy_denied` | Refused by policy (the server uses this for policy denials) |
| `timeout` | Operation timed out |
| `unavailable` | A dependency (API, CLI, network) is unavailable; retrying later may work |
| `internal` | Unexpected/fallback error |

Other type strings are accepted (for example `cli_error` or `network_error`); prefer the documented ones so clients can rely on them.

Some SDK helpers report failures in their own output rather than as a tool result, with these `error.type` values:

| Type | Produced by |
|------|-------------|
| `redirect` | `mcp_download_safe` on a 3xx response (see `.error.location` for the target) |
| `path_not_found` | `mcp_json_truncate`: `--array-path` points to a missing key |
| `invalid_array_path` | `mcp_json_truncate`: path exists but is not an array |
| `invalid_path_syntax` | `mcp_json_truncate`: malformed jq path |
| `output_too_large` | `mcp_json_truncate`: response too large even with an empty array |

Check for these in the tool and turn them into an `mcp_fail --type` call with a hint (see `examples/12-config-and-downloads`).

#### Result helpers

For successful results:

```bash
# structuredContent is exactly this JSON; the text block is its serialization
mcp_result_json '{"items": [], "count": 42}'

# Plain text, no structuredContent
mcp_result_text "Deleted 3 files"
```

Unlike `mcp_fail --type`, these helpers **do not end the tool**: in an early-return branch, follow them with `exit 0`. With `mcp_result_json` the tool's `outputSchema` describes the JSON itself (there is no `{success, result}` wrapper). See [BEST-PRACTICES.md §4.8](BEST-PRACTICES.md#48-building-calltoolresult-responses) for full documentation.

The 1.x helpers `mcp_result_success`, `mcp_result_error`, `mcp_error`, `mcp_fail_invalid_args` and numeric `mcp_fail CODE MESSAGE` still work in 1.x but are removed in 2.0; `mcp-bash migrate` lists them and rewrites the ones it can. <!-- lint-api-usage: allow -->
`mcp_result_success`/`mcp_result_error` wrap data in a `{success, result}`/`{success, error}` envelope, `mcp_error` and `mcp_result_*` do not end the tool, and the numeric `mcp_fail` form returns a JSON-RPC protocol error the model can't see. <!-- lint-api-usage: allow -->

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
| `-32602` | Invalid params (non-string `protocolVersion`, invalid cursor/log level, missing/invalid remote token) | `handlers/lifecycle.sh`, `handlers/completion.sh`, `handlers/logging.sh`, `lib/auth.sh`, registry cursors |
| `-32603` | Internal errors (empty handler response, registry size/parse failures, tool output/stderr over limits, provider failures, a request that timed out: `<method> timed out after Ns`) | `lib/core.sh`, `lib/tools.sh`, `lib/resources.sh`, `lib/prompts.sh` |
| `-32001` | Tool cancelled (SIGTERM/INT from client) | `lib/tools.sh` |
| `-32000` | Server not initialized (a request for a method the server implements, other than `ping`, before `initialize` completes; an unknown method such as `server/discover` gets `-32601` instead) | `lib/core.sh` |
| `-32002` | Resource not found (`resources/read`) | `lib/resources.sh` |
| `-32003` | Server shutting down (rejecting new work) | `lib/core.sh` |
| `-32005` | `exit` called before `shutdown` was requested | `handlers/lifecycle.sh` |

Size guardrails: `mcp_core_guard_response_size` rejects oversized responses with `-32603` (tool/resource reads use `MCPBASH_MAX_TOOL_OUTPUT_SIZE`, default 10MB; registry/list payloads use `MCPBASH_REGISTRY_MAX_BYTES`, default 100MB) and does not return partial content.

## Resource provider exit codes
- `file.sh`: `2` outside allowed roots, or the read could not be verified → `-32603`; `3` missing file → `-32002`; `5` reading the file failed, `6` file exceeds `MCPBASH_MAX_RESOURCE_BYTES` → `-32603`.
- For exit `2`, the provider's stderr text is the error message when it wrote one; otherwise the message is "Resource outside allowed roots".
- `git.sh`: `4` invalid URI, blocked host (policy, or resolves to a blocked address), missing git, or git older than 2.37 → `-32602`; `5` host does not resolve, or clone/fetch failure → `-32603`.
- `https.sh`: `4` invalid URI, blocked host (policy, or resolves to a blocked address) or missing curl → `-32602`; `5` host does not resolve, network/timeout → `-32603`; `6` payload exceeds `MCPBASH_HTTPS_MAX_BYTES` → `-32603`.
- Any other provider exit code maps to `-32603` with stderr text when available.

## Troubleshooting Quick Hits
- **Unsupported protocol version**: Not an error. When a client requests a version the server does not support, `initialize` succeeds with the latest supported version (`2025-11-25`) and the server logs `client requested unsupported protocol version …` to stderr. If the client then disconnects, update it or have it request `2025-11-25`/`2025-06-18`/`2025-03-26`/`2024-11-05`.
- **Invalid protocol version (`-32602`)**: `protocolVersion` was not a string. `error.data.supported` lists the accepted versions and `error.data.requested` echoes the value sent.
- **Invalid cursor (`-32602`)**: Drop the cursor to restart pagination; ensure clients do not cache cursors across registry refreshes.
- **Tool timed out (`isError: true`, `structuredContent.error.type: "timeout"`)**: The tool exceeded its time limit. Check `structuredContent.error.reason` for context:
  - `"fixed"` – Static timeout elapsed (progress-aware timeout disabled).
  - `"idle"` – Progress-aware timeout enabled, but no activity detected (pattern match or progress emission) within the idle window.
  - `"max_exceeded"` – Progress-aware timeout enabled, tool showed activity but hit the hard cap (`maxTimeoutSecs`).

  Fix: Reduce workload, raise `timeoutSecs` in `<tool>.meta.json`, enable `progressExtendsTimeout` for long-running tools that emit progress, or adjust `MCPBASH_MAX_TIMEOUT_SECS` for the hard cap. Add `timeoutHint` to provide actionable guidance in the error message. See [Timeout Strategy Guide](BEST-PRACTICES.md#timeout-strategy-guide) for detailed configuration guidance.
- **Prompt render failed (`-32603`)**: Ensure the prompt file exists and is readable.
- **Resource/provider failures (`-32603`, message includes provider detail such as "Unable to read resource")**: Confirm the provider exists (`file`, `git`, `https`, `ui`, or a project provider in `providers/`), the URI is valid, and the payload is within `MCPBASH_MAX_RESOURCE_BYTES`.
- **`resources/read timed out after 120s` (`-32603`)**: the provider ran longer than `MCPBASH_DEFAULT_RESOURCE_TIMEOUT` (default 120s) and was stopped. Raise it, set it to `0` to disable, or have the client send `timeoutSecs`.
- **Minimal mode responses (`-32601`)**: Ensure `jq`/`gojq` is available or unset `MCPBASH_FORCE_MINIMAL` to enable tools/resources/prompts.
- **jq parse error in tool output**: Often caused by external CLI failures producing empty stdout. Using `2>/dev/null` hides stderr but doesn't prevent empty output—add `|| echo '{}'` fallback. See [BEST-PRACTICES.md § Calling external CLI tools](BEST-PRACTICES.md#calling-external-cli-tools).
- **`mcp_result_json` returns an `internal` error result**: The argument was empty or (with jq/gojq available) not a single valid JSON value. Without JSON tooling (minimal mode, see `MCPBASH_MODE`) the helper cannot validate: an object is passed through as `structuredContent` unchecked and any other value is sent as text only.
- **mcp_is_valid_json rejects valid-looking JSON**: The helper validates single JSON values only; arrays with multiple root objects or trailing content are rejected. Use `jq -e . >/dev/null 2>&1` for lenient validation.
- **mcp_json_truncate not truncating**: Ensure the second argument (max_bytes) is a positive integer. Non-numeric values default to 102400 (100KB).

## Operational Safeguards

- A failed write to stdout means the client stopped reading: the server stops at once (from the main loop or from a tool worker) and logs "the client stopped reading, shutting down" to stderr. Tools still running are stopped (TERM, then KILL after 1 second), as on SIGTERM/SIGINT or a dead parent. `MCPBASH_ALLOW_CORRUPT_STDOUT` does not change this.
- Stdout corruption (multi-line payloads, non-UTF-8 payloads) is counted; when the count within `MCPBASH_CORRUPTION_WINDOW` reaches `MCPBASH_CORRUPTION_THRESHOLD`, the server stops.
- Registry refresh enforces `MCPBASH_REGISTRY_MAX_BYTES`; exceeding the limit or encountering parse failures returns `-32603` and preserves the previous registry snapshot.
- Resource and tool payloads are capped by `MCPBASH_MAX_RESOURCE_BYTES` and `MCPBASH_MAX_TOOL_OUTPUT_SIZE`/`MCPBASH_MAX_TOOL_STDERR_SIZE`; breaches return `-32603` with a logged diagnostic.
- Minimal mode (missing JSON tooling or `MCPBASH_FORCE_MINIMAL=true`) accepts lifecycle, ping, and logging; other methods return `-32601` to avoid partial/ambiguous behavior.
