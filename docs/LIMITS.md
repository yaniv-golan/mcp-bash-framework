# Operational Limits

- Default concurrency: 16 worker slots (`MCPBASH_MAX_CONCURRENT_REQUESTS`) configurable via env.
- Default tool timeout: 30 seconds; override globally or per metadata (`timeoutSecs`).
- Default `resources/read` and `resources/subscribe` timeouts: 120 seconds (`MCPBASH_DEFAULT_RESOURCE_TIMEOUT`, `MCPBASH_DEFAULT_SUBSCRIBE_TIMEOUT`; `0` disables). A request's `params.timeoutSecs` overrides them. A request stopped by its timeout gets `-32603`.
- Resource payloads are capped by `MCPBASH_MAX_RESOURCE_BYTES` (default: the tool output limit, 10MB); `file://` reads stop at the limit. `ui://` resources are capped by `MCPBASH_MAX_UI_RESOURCE_BYTES` (default 1 MiB). A value that is not a plain byte count means the default.
- Tool/stdout responses larger than 10MB are rejected (no truncation) with `-32603`. Tune via `MCPBASH_MAX_TOOL_OUTPUT_SIZE`; stderr guard uses `MCPBASH_MAX_TOOL_STDERR_SIZE` (defaults to the same limit).
- Progress notifications are throttled to 100/minute per request; rate can be tuned with `MCPBASH_MAX_PROGRESS_PER_MIN`. Logging shares the same ceiling unless `MCPBASH_MAX_LOGS_PER_MIN` is set.
- Large argument/metadata payloads are written to temp files when they exceed `MCPBASH_ENV_PAYLOAD_THRESHOLD` (default 64KB) to keep envs small.
- Completion scripts are the exception: they get the request arguments and the prompt or resource metadata in environment variables (`MCP_COMPLETION_ARGS_JSON`, `MCP_PROMPT_METADATA`, `MCP_RESOURCE_METADATA`), never in temp files. Linux refuses to start a program when one variable is over 128 KiB, so the request fails with `-32603` ("Argument list too long"). The usual cause is a large local icon on the prompt or resource, since icons are inlined as base64 data URIs. Keep such icons under about 90 KB.
- Registries fail fast if serialized size exceeds `MCPBASH_REGISTRY_MAX_BYTES` (default 100MB) to protect disk usage.
- When a limit is exceeded, the entire response is replaced with a JSON-RPC error (`-32603`); partial payloads are not returned.
