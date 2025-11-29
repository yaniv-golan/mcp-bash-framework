# 03-progress-and-cancellation

**What you’ll learn**
- Emitting progress notifications with a progress token
- Cooperative cancellation surfaced as `-32001` cancellation
- Structured output when jq/gojq is available; minimal mode disables this example

**Prereqs**
- Bash 3.2+
- jq or gojq required; without it the server enters minimal mode and this example is unavailable

**Run**
```
./examples/run 03-progress-and-cancellation
```

**Transcript**
```
> tools/call example.slow {"_meta":{"progressToken":"token-1"}}
< notifications/progress ... "Working (10%)"
< notifications/progress ... "Working (50%)"
> notifications/cancelled {"requestId":"1"}
< {"error":{"code":-32001,"message":"Cancelled","isError":true}}
```

**Success criteria**
- Progress notifications arrive while the tool runs when `_meta.progressToken` is set
- Cancellation returns `-32001` and stops further progress updates

**Troubleshooting**
- Ensure scripts are executable (`chmod +x examples/run examples/03-progress-and-cancellation/tools/*.sh`).
- If you don’t see progress, include `_meta.progressToken` in the call.
- If you see minimal-mode warnings, install jq/gojq; minimal mode disables tools/resources/prompts.
- Avoid CRLF in requests; send LF-only NDJSON.
