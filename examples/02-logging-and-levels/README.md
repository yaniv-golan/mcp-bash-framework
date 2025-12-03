# 02-logging-and-levels

**What you’ll learn**
- Emitting structured logs from a tool
- Changing verbosity via `logging/setLevel`
- Structured output when jq/gojq is available; minimal mode disables this example

**Prereqs**
- Bash 3.2+
- jq or gojq required; without it the server enters minimal mode and this example is unavailable

**Run**
```
./examples/run 02-logging-and-levels
```

**Transcript**
```
> logging/setLevel {"level":"debug"}
> tools/call example.logger
< notifications/message ... "example.logger" ...
< {"result":{"content":[{"type":"text","text":"Check your logging notifications"}]}}
```

**Success criteria**
- `tools/list` shows `example.logger`
- Setting level to `debug` yields `notifications/message` entries from the tool

**Troubleshooting**
- Ensure scripts are executable (`chmod +x examples/run examples/02-logging-and-levels/tools/*/tool.sh`).
- If no logs appear, confirm `logging/setLevel` to `debug` or `info`.
- If you see minimal-mode warnings, install jq/gojq; minimal mode disables tools/resources/prompts.
- Avoid CRLF in requests; send LF-only NDJSON.
- To see full paths in debug logs or manual-registration output in warnings/errors, set `MCPBASH_LOG_VERBOSE=true` (security risk: exposes file paths and usernames).
