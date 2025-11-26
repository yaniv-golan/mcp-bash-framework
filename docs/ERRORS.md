# Error Handling Guidelines

- Tool/resource failures return `isError=true` with `_meta.exitCode` and captured stderr.
- Malformed tool output triggers a substitution with an error payload and a logged incident.
- Registry or discovery errors fall back to minimal capabilities while emitting `notifications/message` with severity `error`.
- Manual overrides should return well-formed JSON; otherwise auto-discovery resumes and issues `listChanged` notifications.

## JSON-RPC Error Codes

| Code | When emitted | Source |
|------|--------------|--------|
| `-32700` | Parse errors and invalid JSON normalization | `lib/core.sh` |
| `-32600` | Invalid request (missing method, batch arrays when disabled) | `lib/core.sh` |
| `-32601` | Unknown or disallowed method (`notifications/message` from client, missing handler, not found) | `lib/core.sh`, `handlers/*` |
| `-32602` | Invalid params (unsupported protocol version, invalid cursor, invalid log level) | `handlers/lifecycle.sh`, `handlers/completion.sh`, `handlers/logging.sh`, registry cursors |
| `-32603` | Internal errors (empty handler response, registry size/parse failures, tool output/stderr over limits, provider failures) | `lib/core.sh`, `lib/tools.sh`, `lib/resources.sh`, `lib/prompts.sh` |
| `-32001` | Tool cancelled (SIGTERM/INT from client) | `lib/tools.sh` |
| `-32002` | Server not initialized (`initialize` not completed) | `lib/core.sh` |
| `-32003` | Server shutting down (rejecting new work) | `lib/core.sh` |
| `-32004` | Tool timed out | `lib/tools.sh` |
| `-32005` | `exit` called before `shutdown` was requested | `handlers/lifecycle.sh` |

Size guardrails: `mcp_core_guard_response_size` rejects oversized responses (default 10MB) with `-32603` and does not return partial content.
