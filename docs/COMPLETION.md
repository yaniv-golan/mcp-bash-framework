# Completion Support

`completion/complete` is available in full mode (disabled in minimal mode). Completions are manually registered via `server.d/register.sh`; there is no auto-discovery. Providers can be `builtin`, `manual` (scripts), `prompt`, or `resource`. Use `mcp-bash scaffold completion <name>` to create a starter script and register it automatically.

## Registering Completions

```bash
# server.d/register.sh
mcp_completion_manual_begin
mcp_completion_register_manual '{"name":"example.completion","path":"completions/suggest.sh","timeoutSecs":5}'
mcp_completion_manual_finalize
```

- `name` must be unique. Clients call `completion/complete` with this name.
- `path` is relative to `MCPBASH_PROJECT_ROOT` for `manual` providers.
- `timeoutSecs` is optional; defaults to no per-request timeout (global watchdogs still apply).
- The registry rejects duplicates, missing paths, or buffer overflows (guarded by `MCPBASH_MANUAL_BUFFER_MAX_BYTES`).

## Provider Types
- **builtin**: fallback generator when no registration matches.
- **manual**: executable script under project root (most common).
- **prompt**: script under `prompts/` (receives prompt metadata via env).
- **resource**: script under `resources/` (receives resource metadata via env).

## Script Contract (manual provider)

Environment variables:
- `MCP_COMPLETION_NAME` – completion name (string).
- `MCP_COMPLETION_ARGS_JSON` – JSON object from `params.arguments` (use `jq`/`gojq`).
- `MCP_COMPLETION_LIMIT` – max suggestions requested (int; capped at 100).
- `MCP_COMPLETION_OFFSET` – pagination offset (int).
- `MCP_COMPLETION_ARGS_HASH` – opaque hash for cursor binding.

Stdout (any of):
- JSON array of suggestions:
  ```json
  [{"type":"text","text":"alpha"},{"type":"text","text":"beta"}]
  ```
- Object with `suggestions` plus pagination fields:
  ```json
  {
    "suggestions": [{"type":"text","text":"alpha"}],
    "hasMore": true,
    "next": 1,             // optional numeric offset for next page
    "cursor": "opaque"      // optional cursor string (takes precedence over next)
  }
  ```

`type` is typically `"text"`; other content types are supported by the MCP schema.

## Minimal Mode
- Completion is declined with `-32601` when JSON tooling is unavailable or `MCPBASH_FORCE_MINIMAL=true`.
- Scripts still need `jq`/`gojq` to parse arguments; `MCPBASH_JSON_TOOL_BIN` is exported.

## Pagination Rules
- Limit requested by client is capped to 100.
- If `hasMore` is true and `cursor` is empty, the framework derives a cursor from `next` (or offset + count).
- If `cursor` is provided, it is returned as `nextCursor` unmodified; subsequent requests include it in `params.cursor`.

## Example Flow
See `examples/10-completions`:
- Registers `demo.completion` via `server.d/register.sh`.
- Script reads `arguments.query` (or `prefix`) from `MCP_COMPLETION_ARGS_JSON`, filters suggestions, and paginates with `hasMore`.
- `completion/complete` returns suggestions, `hasMore`, and `nextCursor` until results are exhausted.
