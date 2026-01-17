# MCP Inspector Playbook

This guide is a practical set of recipes for testing `mcp-bash` servers with **MCP Inspector** and for debugging failures that come from **strict client validation** (schema/shape mismatches).

## Prerequisites

- **Node.js 22.7.5+** required by MCP Inspector
- `npx` available in PATH (or install Inspector globally)

## Recommended approach

- **Prefer raw stdio transcripts** (NDJSON in, NDJSON out) for correctness testing.
- Use **MCP Inspector UI** for quick manual exploration, but treat it as “best effort” when proxy/browser issues get in the way.
- When a strict client fails, validate the exact JSON with `jq` (types + optional fields) rather than eyeballing.

## Raw stdio testing (most reliable)

Create a request transcript and run the server over stdio:

```bash
cat >requests.ndjson <<'EOF'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"tools","method":"tools/list","params":{}}
EOF

MCPBASH_PROJECT_ROOT=/path/to/project ./bin/mcp-bash <requests.ndjson >responses.ndjson
```

Then assert shapes:

```bash
jq -e '
  select(.id=="tools")
  | (.result.tools | type) == "array"
' responses.ndjson
```

## Using `mcp-bash debug`

When a client reports “invalid input” or similar, capture the actual JSON-RPC exchange:

```bash
MCPBASH_PROJECT_ROOT=/path/to/project ./bin/mcp-bash debug
```

See [DEBUGGING.md](DEBUGGING.md) for log analysis tooling.

## Common strict-client pitfalls (what to check first)

- **Optional fields**: if a field is optional and typed as `string`, prefer **omitting** it instead of emitting `null`.
  - Examples: `nextCursor` in list results, `nextCursor` in `completion/complete`.
- **Resource templates discoverability**: templates are accessed via `resources/templates/list`, but are not advertised via a dedicated server capability flag; probe the method (and treat `-32601` as “unsupported”).
- **prompts/list `arguments`**: must be an **array** of `{name, description?, required?}`, not a JSON Schema object.
- **prompts/get message content**: `messages[].content` is a **single content object**, not an array.
- **resources/read is URI-addressed**: custom providers need metadata to be found by `uri`.

## Inspector UI gotchas (when it’s not the server)

If the web UI fails to connect even though stdio works:

- Prefer Inspector CLI or raw stdio transcripts.
- On macOS, `localhost` can resolve to IPv6 first; some proxies bind only IPv4. If possible, use `127.0.0.1`.
- Watch for proxy query strings with malformed env blocks (e.g., `env=undefined`).
- **“CORS policy / No Access-Control-Allow-Origin” during connect** can be caused by the **Inspector’s `/stdio` URL getting too long**. The Inspector UI encodes environment variables into a URL query parameter, and a huge `PATH` can push the request past practical limits.
  - Fix in the UI: add an **Environment Variable** for `PATH` with a short value (or remove other large env vars).
  - Fix when launching Inspector: run it with a minimal `PATH` (use an absolute `npx` path if needed), e.g.:
    ```bash
    CLIENT_PORT=6324 SERVER_PORT=6327 \
    PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin' \
    /opt/homebrew/bin/npx --yes @modelcontextprotocol/inspector --transport stdio -- \
    ./examples/run 10-completions
    ```
- **403 “Invalid origin”** (DNS rebinding protection): set `ALLOWED_ORIGINS` to include the Inspector UI origin you’re using (often both `http://localhost:$CLIENT_PORT` and `http://127.0.0.1:$CLIENT_PORT`).

## Inspector CLI (scriptable; no browser)

MCP Inspector also has a CLI mode that can invoke a small set of methods (tools/resources/prompts/logging). This avoids the UI proxy and is useful for quick smoke checks.

### Built-in command generator

To get the command for running MCP Inspector on your project:

```bash
mcp-bash validate --inspector
```

This prints the exact `npx` command with your project's paths configured. Copy and run it to open an interactive CLI where you can test methods and see schema violations.

### Manual invocation

For more control, invoke Inspector CLI directly:

```bash
/opt/homebrew/bin/npx --yes @modelcontextprotocol/inspector --cli --transport stdio -- \
./examples/run 10-completions --method logging/setLevel --log-level debug
```

Notes:
- The CLI currently does **not** support `completion/complete`. For completions, use the Inspector UI or raw stdio transcripts.

## Conformance tests

This repo includes a strict conformance test that exercises the same shape constraints Inspector enforces:

- `test/integration/test_conformance_strict_shapes.sh`
- `test/conformance/run.sh` (runs conformance under `jq` and `gojq` when available)
