# MCP Roots Support

MCP Roots let clients tell the server which filesystem areas are in scope. mcp-bash uses the standard `roots/list` flow and exposes the resulting roots to tools.

## How it works
- During `initialize`, the lifecycle handler records whether the client advertises `roots` and `roots.listChanged`.
- After `initialized`, the server sends `roots/list` to the client. Responses are matched via the RPC callback registry.
- If a client emits `notifications/roots/list_changed`, the server re-requests roots (debounced).
- While a refresh is in flight, the cached roots remain available; client responses replace the cache on success.
- Timeouts or client errors keep the existing roots (no noisy warnings); malformed client payloads are ignored.

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
Priority (highest to lowest):
1. `--roots` flag to `mcp-bash run-tool` (run-tool only; comma-separated)
2. `MCPBASH_ROOTS=/path/one:/path/two` (colon-separated; absolute or relative to `MCPBASH_PROJECT_ROOT`)
3. `config/roots.json` in your project:
   ```json
   {
     "roots": [
       { "path": "./data", "name": "Data" },
       { "path": "/shared/media", "name": "Media" }
     ]
   }
   ```
4. Default: `MCPBASH_PROJECT_ROOT` (implicit single root)

Behavior:
- `--roots` / `MCPBASH_ROOTS` fail fast on invalid paths (non-existent or unreadable).
- `config/roots.json` warns and skips invalid entries but keeps valid ones.
- Client roots replace the current cache on success; malformed client payloads keep the previous roots.

## Try it
- Run `./examples/run 08-roots-basics` and call `example.roots.read` with `./data/sample.txt` (allowed) and `/etc/passwd` (denied).
- In the advanced ffmpeg-studio example, paths are scoped by client roots; if none are provided, it falls back to the bundled `./media`.

## Path requirements
- All roots must exist and be readable; mcp-bash will not create directories.
- Paths are canonicalized (symlinks resolved where possible) before comparison, and drive letters are normalized on Windows/MSYS.
- Only `file://` URIs are accepted from clients; non-local authorities are rejected.
- Relative paths in `MCPBASH_ROOTS` or `config/roots.json` resolve against `MCPBASH_PROJECT_ROOT`.

## Logging and safety
- Only `file://` URIs are accepted; non-local authorities are rejected.
- Paths are percent-decoded, normalized via `realpath`, and deduplicated before use.
- Late/stale responses are dropped using a generation counter so they cannot overwrite newer roots.
