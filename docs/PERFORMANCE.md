# Performance Guide

## Quick benchmarks
- Capture a baseline with `time bin/mcp-bash < sample.json` (or the compatibility fixture in `test/compatibility/`) before making concurrency or timeout changes.
- Run `test/integration/test_capabilities.sh` to exercise discovery, pagination, and registry notifications under load.
- Use `MCPBASH_DEBUG_PAYLOADS=true` sparingly while debugging to avoid skewing timings with disk I/O.

## Tuning levers
- **Concurrency**: `MCPBASH_MAX_CONCURRENT_REQUESTS` (default 16) sets worker slots. Increase gradually and watch CPU steal/memory pressure; decrease on small hosts.
- **Timeouts**: Set per-tool `timeoutSecs` in `<tool>.meta.json`; global default comes from `MCPBASH_DEFAULT_TOOL_TIMEOUT` (30s by default).
- **Registry scans**: Adjust TTLs (`MCP_TOOLS_TTL`, `MCP_RESOURCES_TTL`, `MCP_PROMPTS_TTL`) and scope (`MCPBASH_REGISTRY_REFRESH_PATH`) to reduce filesystem churn on large trees.
- **Very large registries**: If you have hundreds/thousands of tools/resources/prompts, prefer manual registration hooks over auto-discovery to avoid `find`/`stat` overhead across huge trees.
- **Resource polling**: `MCPBASH_RESOURCES_POLL_INTERVAL_SECS` controls subscription polling (poller starts after the first `resources/subscribe`); use `0` to disable when live updates are unnecessary.
- **Progress streaming**: `MCPBASH_ENABLE_LIVE_PROGRESS=true` streams progress/log updates mid-flight (starts a background flusher); tune `MCPBASH_PROGRESS_FLUSH_INTERVAL` (seconds) to balance responsiveness vs overhead.

## Diagnostics
- Enable `MCPBASH_LOG_LEVEL=debug` to log registry fast-path decisions, path resolution, and worker lifecycle events. Add `MCPBASH_LOG_VERBOSE=true` to include full paths in debug output (increases log volume; disable after troubleshooting).
- Inspect `.registry/*.json` sizes and counts when pagination feels slow; large registries may warrant manual registration or narrower scan roots.
- Use `ps`/`top`/`htop` to spot runaway tools; align `timeoutSecs` and watchdogs in `lib/timeout.sh` with observed runtimes.
- On Windows/MSYS, prefer shorter TTLs and smaller payloads to offset filesystem overhead; watch for `MSYS2_ARG_CONV_EXCL` quirks in provider scripts.
