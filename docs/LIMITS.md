# Operational Limits

- Default concurrency: 16 worker slots (`MCPBASH_MAX_CONCURRENT_REQUESTS`) configurable via env.
- Default tool timeout: 30 seconds; override globally or per metadata (`timeoutSecs`).
- Tool/stdout responses larger than 10MB are rejected (no truncation) with `-32603`. Tune via `MCPBASH_MAX_TOOL_OUTPUT_SIZE`; stderr guard uses `MCPBASH_MAX_TOOL_STDERR_SIZE` (defaults to the same limit).
- Progress notifications are throttled to 100/minute per request; rate can be tuned with `MCPBASH_MAX_PROGRESS_PER_MIN`. Logging shares the same ceiling unless `MCPBASH_MAX_LOGS_PER_MIN` is set.
- Large argument/metadata payloads are written to temp files when they exceed `MCPBASH_ENV_PAYLOAD_THRESHOLD` (default 64KB) to keep envs small.
- Registries fail fast if serialized size exceeds `MCPBASH_REGISTRY_MAX_BYTES` (default 100MB) to protect disk usage.
- When a limit is exceeded, the entire response is replaced with a JSON-RPC error (`-32603`); partial payloads are not returned.
