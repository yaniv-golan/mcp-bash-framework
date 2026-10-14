# Operational Limits

- Default concurrency: 16 worker slots (`MCPBASH_MAX_CONCURRENT_REQUESTS`) configurable via env.
- Default tool timeout: 30 seconds; override globally or per metadata (`timeoutSecs`).
- Default `resources/read` and `resources/subscribe` timeouts: 120 seconds (`MCPBASH_DEFAULT_RESOURCE_TIMEOUT`, `MCPBASH_DEFAULT_SUBSCRIBE_TIMEOUT`; `0` disables). A request's `params.timeoutSecs` overrides them. A request stopped by its timeout gets `-32603`.
- Resource payloads are capped by `MCPBASH_MAX_RESOURCE_BYTES` (default: the tool output limit, 10MB); `file://` reads stop at the limit. `ui://` resources are capped by `MCPBASH_MAX_UI_RESOURCE_BYTES` (default 1 MiB). A value that is not a plain byte count means the default.
- Tool stdout larger than 10MB is rejected (no truncation): the call returns an error result with type `output_too_large` (a `-32603` JSON-RPC error before 2.0). Tune via `MCPBASH_MAX_TOOL_OUTPUT_SIZE`; stderr guard uses `MCPBASH_MAX_TOOL_STDERR_SIZE` (defaults to the same limit).
- Progress notifications are throttled to 100/minute per request; rate can be tuned with `MCPBASH_MAX_PROGRESS_PER_MIN`. Logging shares the same ceiling unless `MCPBASH_MAX_LOGS_PER_MIN` is set.
- Tools: large argument/metadata payloads are written to temp files when they exceed `MCPBASH_ENV_PAYLOAD_THRESHOLD` (default 64KB) to keep envs small.
- Completion scripts get the request arguments and the prompt or resource metadata in files of any size (`MCP_COMPLETION_ARGS_FILE`, `MCP_PROMPT_METADATA_FILE`, `MCP_RESOURCE_METADATA_FILE`; since 2.0). Before 2.0 they came in environment variables, and Linux refused to start the script when one was over 128 KiB (for example a prompt with a large local icon, inlined as a base64 data URI).
- Registries fail fast if serialized size exceeds `MCPBASH_REGISTRY_MAX_BYTES` (default 100MB) to protect disk usage.
- When a limit is exceeded, the entire response is replaced with an error (an `output_too_large` error result for tool output, a JSON-RPC `-32603` otherwise); partial payloads are not returned.
