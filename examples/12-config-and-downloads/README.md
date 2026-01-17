# 12-config-and-downloads

**What you'll learn**
- Load configuration from multiple sources with `mcp_config_load` (env var > file > defaults)
- Extract config values with `mcp_config_get` including default fallbacks
- Securely fetch external URLs with `mcp_download_safe` (SSRF protection, retries)
- Use `mcp_download_safe_or_fail` for fail-fast download pattern
- Return LLM-friendly errors with `mcp_error --hint` for self-correction
- Handle redirect responses gracefully

**Prereqs**
- Bash 3.2+
- jq or gojq required; without it the server enters minimal mode and this example is unavailable
- curl required for downloads

**Run**
```
./examples/run 12-config-and-downloads
```

**Transcript**
```
> tools/call {"name":"fetch-api-data","arguments":{"url":"https://httpbin.org/get"}}
< {"result":{"content":[{"type":"text","text":"{\"success\":true,\"result\":{...}}"}]}}

> tools/call {"name":"fetch-api-data","arguments":{"url":"https://httpbin.org/redirect/1"}}
< {"result":{"content":[{"type":"text","text":"{\"success\":false,\"error\":{\"type\":\"redirect\",...}}"}],"isError":true}}
```

**Config precedence**
1. `FETCH_API_CONFIG` env var (JSON string or file path)
2. `config.json` in project root
3. `config.example.json` defaults
4. Inline defaults in the tool

**Success criteria**
- Tool fetches data when URL is in allowlist
- Returns structured error with hint when URL is blocked
- Handles redirects with actionable hint showing target location
- Config values are loaded with proper precedence

**Troubleshooting**
- If download fails with `host_blocked`, check `MCPBASH_HTTPS_ALLOW_HOSTS` or use `--allow` parameter
- For timeout issues, adjust `timeout` in config or use `--timeout` flag
- Install jq/gojq; minimal mode disables tools/resources/prompts
- Run with `MCPBASH_LOG_LEVEL=debug` to see config loading details
