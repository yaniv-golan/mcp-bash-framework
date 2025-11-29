# 05-prompts-basics

**What you’ll learn**
- Discovering prompts and rendering a simple template
- Calling `prompts/list` and `prompts/get` with one argument

**Prereqs**
- Bash 3.2+
- jq or gojq required; otherwise the server enters minimal mode and prompts are unavailable

**Run**
```
./examples/run 05-prompts-basics
```

**Transcript**
```
> prompts/list
< {"result":{"prompts":[{"name":"prompt.greeting",...}]}}
> prompts/get {"name":"prompt.greeting","arguments":{"name":"Ada"}}
< {"result":{"messages":[{"role":"system","content":[{"type":"text","text":"Hello, Ada! Welcome to MCP prompts."}]}]}}
```

**Success criteria**
- `prompts/list` shows `prompt.greeting`
- `prompts/get` renders the greeting with the provided `name`

**Troubleshooting**
- Prompts are unavailable in minimal mode; install jq/gojq.
- Ensure files are present (`examples/05-prompts-basics/prompts/*`).
- Avoid CRLF in requests; send LF-only NDJSON.
