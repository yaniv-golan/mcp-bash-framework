# 00-hello-tool

**What you’ll learn**
- Basic handshake (`initialize`/`initialized`) and auto-discovered tools
- Structured vs text output depending on jq/gojq availability (no Python fallback)
- Runner sets `MCP_SDK` automatically

**Prereqs**
- Bash 3.2+
- jq or gojq required; without it the server enters minimal mode and this example is unavailable

**Run**
```
./examples/run 00-hello-tool
```

**Transcript**
```
> initialize
< {"result":{"capabilities":{...}}}
> tools/call example.hello
< {"result":{"content":[{"type":"text","text":"Hello from example tool"}]}}
```

**Success criteria**
- `tools/list` shows `example.hello`
- Calling `example.hello` returns a greeting (text or structured if jq/gojq is present)

**Troubleshooting**
- Ensure scripts are executable (`chmod +x examples/run examples/00-hello-tool/tools/*/tool.sh`).
- If you see minimal-mode warnings, install jq/gojq; minimal mode disables tools/resources/prompts entirely.
- Avoid CRLF in requests; send LF-only NDJSON.
