# Completion Support

`completion/complete` is available in full mode (disabled in minimal mode). Completions are manually registered (there is no auto-discovery). Prefer declarative registration via `server.d/register.json`; hook-based registration via `server.d/register.sh` is still supported but executes shell code and is opt-in (`MCPBASH_ALLOW_PROJECT_HOOKS=true` plus safe ownership/permissions).

## Registering Completions

```json
// server.d/register.json
{
  "version": 1,
  "completions": [
    {"name": "example.completion", "path": "completions/suggest.sh", "timeoutSecs": 5}
  ]
}
```

- `name` must be unique. Clients reference it via `params.ref` in `completion/complete` requests.
- `path` is relative to `MCPBASH_PROJECT_ROOT` for `manual` providers.
- `timeoutSecs` is optional; defaults to no per-request timeout (global watchdogs still apply).
- The registry rejects duplicates, missing paths, or buffer overflows (guarded by `MCPBASH_MANUAL_BUFFER_MAX_BYTES`).

## Client request shape (MCP 2025-11-25)

Use `ref` + `argument`:

```json
{
  "jsonrpc": "2.0",
  "id": "c1",
  "method": "completion/complete",
  "params": {
    "ref": {"type": "ref/prompt", "name": "demo.completion"},
    "argument": {"name": "query", "value": "re"},
    "limit": 3,
    "context": {"arguments": {}}
  }
}
```

Notes:
- `ref/prompt` uses the prompt name (this maps to the completion provider name for manual completions).
- `ref/resource` uses `ref.uri`; mcp-bash resolves it to a registered resource name when possible.

## Provider Types
- **builtin**: fallback generator when no registration matches.
- **manual**: executable script under project root (most common).
- **prompt**: script under `prompts/` (receives prompt metadata via env).
- **resource**: script under `resources/` (receives resource metadata via env).

## Script Contract (manual provider)

Environment variables:
- `MCP_COMPLETION_NAME` – completion name (string).
- `MCP_COMPLETION_ARGS_JSON` – JSON object derived from the request params:
  - a normalized object that includes `query`/`prefix` (from `params.argument.value`) plus `ref` and `context.arguments`
- `MCP_COMPLETION_LIMIT` – max suggestions requested (int; capped at 100).
- `MCP_COMPLETION_OFFSET` – pagination offset (int).
- `MCP_COMPLETION_ARGS_HASH` – opaque hash for cursor binding.

Recommended parsing:
```bash
# Prefer .query; fall back to .prefix; treat missing as empty string.
query="$(printf '%s' "${MCP_COMPLETION_ARGS_JSON:-{}}" | jq -r '(.query // .prefix // "")')"
```

Stdout (any of):
- JSON array of suggestions:
  ```json
  ["alpha","beta"]
  ```
- Object with `suggestions` plus pagination fields:
  ```json
  {
    "suggestions": ["alpha"],
    "hasMore": true,
    "next": 1,             // optional numeric offset for next page
    "cursor": "opaque"      // optional cursor string (takes precedence over next)
  }
  ```

Notes:
- Providers must emit **`string[]`** suggestions (and `suggestions` must be `string[]` when using the object form).

## Minimal Mode
- Completion is declined with `-32601` when JSON tooling is unavailable or `MCPBASH_FORCE_MINIMAL=true`.
- Scripts still need `jq`/`gojq` to parse arguments; `MCPBASH_JSON_TOOL_BIN` is exported.

## Pagination Rules
- Limit requested by client is capped to 100.
- If `hasMore` is true and `cursor` is empty, the framework derives a cursor from `next` (or offset + count).
- If `cursor` is provided, it is returned as `nextCursor` unmodified; subsequent requests include it in `params.cursor`.

## Example Flow
See `examples/10-completions`:
- Registers `demo.completion` via `server.d/register.json`.
- Script reads `.query` (or `.prefix`) from `MCP_COMPLETION_ARGS_JSON`, filters suggestions, and paginates with `hasMore`.
- `completion/complete` returns suggestions, `hasMore`, and `nextCursor` until results are exhausted.

If you need **dynamic/imperative** completion registration (for example, generate names from the filesystem or gate entries on env vars), see `examples/advanced/register-sh-hooks/` which uses `server.d/register.sh` (opt-in).
