# 04-resources-basics

**What you’ll learn**
- Discovering resources and reading a file via the built-in file provider
- Using `resources/list` and `resources/read` from a client
- Where to find resource metadata under `resources/`

**Prereqs**
- Bash 3.2+
- jq or gojq required; without it the server enters minimal mode and this example is unavailable

**Run**
```
./examples/run 04-resources-basics
```

**Transcript**
```
> resources/list
< {"result":{"resources":[{"name":"example.greeting","uri":"file://./resources/greeting.txt",...}]}}
> resources/read {"uri":"file://./resources/greeting.txt"}
< {"result":{"contents":[{"type":"text","text":"Hello from a resource file"}]}}
```

**Success criteria**
- `resources/list` shows `example.greeting` with a file:// URI
- `resources/read` returns the greeting text

**Troubleshooting**
- Ensure files are in place (`examples/04-resources-basics/resources/*`) and readable.
- Install jq/gojq; minimal mode disables tools/resources/prompts.
- Avoid CRLF in requests; send LF-only NDJSON.
- For live updates, see `resources/subscribe` in docs (not part of this basic run).
