# MCP Inspector Playbook

This guide is a practical set of recipes for testing `mcp-bash` servers with **MCP Inspector** and for debugging failures that come from **strict client validation** (schema/shape mismatches).

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
- **prompts/list `arguments`**: must be an **array** of `{name, description?, required?}`, not a JSON Schema object.
- **prompts/get message content**: `messages[].content` is a **single content object**, not an array.
- **resources/read is URI-addressed**: custom providers need metadata to be found by `uri`.

## Inspector UI gotchas (when it’s not the server)

If the web UI fails to connect even though stdio works:

- Prefer Inspector CLI or raw stdio transcripts.
- On macOS, `localhost` can resolve to IPv6 first; some proxies bind only IPv4. If possible, use `127.0.0.1`.
- Watch for proxy query strings with malformed env blocks (e.g., `env=undefined`).

## Conformance tests

This repo includes a strict conformance test that exercises the same shape constraints Inspector enforces:

- `test/integration/test_conformance_strict_shapes.sh`
- `test/conformance/run.sh` (runs conformance under `jq` and `gojq` when available)

