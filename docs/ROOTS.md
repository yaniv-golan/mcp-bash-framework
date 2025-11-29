# MCP Roots Support

MCP Roots let clients tell the server which filesystem areas are in scope. mcp-bash uses the standard `roots/list` flow and exposes the resulting roots to tools.

## How it works
- During `initialize`, the lifecycle handler records whether the client advertises `roots` and `roots.listChanged`.
- After `initialized`, the server sends `roots/list` to the client. Responses are matched via the RPC callback registry.
- If a client emits `notifications/roots/list_changed`, the server re-requests roots (debounced).
- While a refresh is in flight, roots are cleared and tools block on `mcp_roots_wait_ready` so they don’t run with stale roots.
- Timeouts or client errors fall back to local roots (env/config below) and mark roots ready.

## Tool environment
Every tool receives these env vars (populated once roots are ready):
- `MCP_ROOTS_JSON` – JSON array of roots with `uri`, `name`, and normalized `path`.
- `MCP_ROOTS_PATHS` – newline-separated list of normalized absolute paths.
- `MCP_ROOTS_COUNT` – number of roots.

SDK helpers in `sdk/tool-sdk.sh`:
- `mcp_roots_list` – prints `MCP_ROOTS_PATHS`.
- `mcp_roots_count` – prints the count.
- `mcp_roots_contains <path>` – returns 0 if the path is within any root.

## Fallbacks (when the client doesn’t supply roots or times out)
Priority:
1. `MCPBASH_ROOTS=/path/one:/path/two` (colon-separated absolute or relative paths; relative paths resolve against `MCPBASH_PROJECT_ROOT`).
2. `config/roots.json` in your project:
   ```json
   {
     "roots": [
       { "path": "./data", "name": "Data" },
       { "path": "/shared/media", "name": "Media" }
     ]
   }
   ```

If neither is present, tools see no roots unless the project/tool implements its own fallback (e.g., the ffmpeg-studio example defaults to its bundled `./media`).

## Try it
- Run `./examples/run 08-roots-basics` and call `example.roots.read` with `./data/sample.txt` (allowed) and `/etc/passwd` (denied).
- In the advanced ffmpeg-studio example, paths are scoped by client roots; if none are provided, it falls back to the bundled `./media`.

## Logging and safety
- Only `file://` URIs are accepted; non-local authorities are rejected.
- Paths are percent-decoded, normalized via `realpath`, and deduplicated before use.
- Late/stale responses are dropped using a generation counter so they cannot overwrite newer roots.
