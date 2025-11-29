# Error Handling Guidelines

- Tool failures return `isError=true` with `_meta.exitCode` and captured stderr; timeouts and cancellation surface as JSON-RPC errors before tool output is returned.
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
| `-32602` | Invalid params (unsupported protocol version, invalid cursor, invalid log level) | `handlers/lifecycle.sh`, `handlers/completion.sh`, `handlers/logging.sh`, registry cursors |
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
- **Unsupported protocol (`-32602`)**: Client requested an older MCP version. Update the client or request `2025-03-26`/`2025-06-18`.
- **Invalid cursor (`-32602`)**: Drop the cursor to restart pagination; ensure clients do not cache cursors across registry refreshes.
- **Tool timed out (`-32603`, message includes "timed out" or "killed")**: Reduce workload or raise `timeoutSecs` in `<tool>.meta.json`; defaults come from `MCPBASH_DEFAULT_TOOL_TIMEOUT`.
- **Resource/provider failures (`-32603`, message includes provider detail such as "Unable to read resource")**: Confirm the provider is supported (`file`, `git`, `https`), URI is valid, and payload size is within `MCPBASH_MAX_RESOURCE_BYTES`.
- **Minimal mode responses (`-32601`)**: Ensure `jq`/`gojq` is available or unset `MCPBASH_FORCE_MINIMAL` to enable tools/resources/prompts.

## Operational Safeguards

- Stdout corruption (multi-line payloads, non-UTF-8, write failures) is counted; exceeding `MCPBASH_CORRUPTION_THRESHOLD` within `MCPBASH_CORRUPTION_WINDOW` triggers a forced exit.
- Registry refresh enforces `MCPBASH_REGISTRY_MAX_BYTES`; exceeding the limit or encountering parse failures returns `-32603` and preserves the previous registry snapshot.
- Resource and tool payloads are capped by `MCPBASH_MAX_RESOURCE_BYTES` and `MCPBASH_MAX_TOOL_OUTPUT_SIZE`/`MCPBASH_MAX_TOOL_STDERR_SIZE`; breaches return `-32603` with a logged diagnostic.
- Minimal mode (missing JSON tooling or `MCPBASH_FORCE_MINIMAL=true`) accepts lifecycle, ping, and logging; other methods return `-32601` to avoid partial/ambiguous behavior.
