# Registry JSON Contracts

The registries are generated automatically at runtime and cached under `$MCPBASH_PROJECT_ROOT/.registry/*.json` to accelerate pagination and reactive notifications. Each registry shares a common envelope and differs only in the shape of the `items` array.

## Common Envelope

All registries adhere to the same top-level structure:

```json
{
  "version": 1,
  "generatedAt": "2025-10-18T09:00:00Z",
  "items": [],
  "hash": "sha256-of-items",
  "total": 0
}
```

- `version`: Schema version (currently `1`).
- `generatedAt`: UTC timestamp when the scan completed.
- `items`: Array containing the discovered entities.
- `hash`: Hash of the canonicalised `items` array; SHA-256 when available, falling back to `cksum` if sha256 utilities are missing. Changed hashes trigger `notifications/*/list_changed`.
- `total`: Count of `items`. This is also surfaced in `tools/list`, `resources/list`, and `prompts/list` responses as a **spec-compliant extension**: the MCP list result schemas require the array fields and allow additional properties, so clients that do not care about `total` can ignore it.

Guardrails are enforced for all registries:

- When `total > 500`, the server logs a warning suggesting manual registration.
- If the serialised registry exceeds `MCPBASH_REGISTRY_MAX_BYTES` (default 100 MB), the scan aborts with `-32603`.

## `.registry/tools.json`

Each entry describes an executable tool. Paths are relative to `MCPBASH_TOOLS_DIR`.
Tool names must match `^[a-zA-Z0-9_-]{1,64}$`; Some clients, including Claude Desktop, enforces this and rejects dotted names, so prefer hyphenated or underscored namespaces.

```json
{
  "version": 1,
  "generatedAt": "2025-10-18T09:00:00Z",
  "items": [
    {
      "name": "example-hello",
      "description": "Return a friendly greeting",
      "path": "hello/tool.sh",
      "inputSchema": {
        "type": "object",
        "properties": {}
      },
      "outputSchema": {
        "type": "object",
        "required": ["message"],
        "properties": {
          "message": { "type": "string" }
        }
      },
      "timeoutSecs": 5,
      "icons": [
        {"src": "https://example.com/hello-icon.svg", "mimeType": "image/svg+xml"}
      ],
      "annotations": {
        "readOnlyHint": true,
        "destructiveHint": false
      }
    }
  ],
  "hash": "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945",
  "total": 1
}
```

**Icons format (MCP 2025-11-25):** The optional `icons` array provides visual identifiers for each item. Each icon object includes:
- `src` (required): URI pointing to the icon — can be:
  - **Local file path**: `"./icon.svg"` or `"icons/logo.png"` — automatically converted to data URIs at registry generation
  - **Data URI**: `"data:image/svg+xml;base64,PHN2Zy4uLg=="`
  - **HTTPS URL**: `"https://example.com/icon.png"`
- `mimeType` (optional): MIME type (e.g., `image/svg+xml`, `image/png`) — auto-detected from file extension for local files
- `sizes` (optional): Array of size specifications (e.g., `["48x48"]`, `["any"]` for SVG)

**Local file example:**
```json
{
  "name": "my-tool",
  "icons": [
    {"src": "./icon.svg"},
    {"src": "https://cdn.example.com/fallback.png", "mimeType": "image/png"}
  ]
}
```
Local paths are resolved relative to the `.meta.json` file location. For stdio transport, data URIs are preferred since clients don't need network access to display the icon.

**Annotations format (MCP 2025-03-26):** The optional `annotations` object provides behavior hints for clients:
- `readOnlyHint` (boolean, default `false`): If `true`, the tool does not modify its environment.
- `destructiveHint` (boolean, default `true`): If `true`, the tool may destructively modify its environment. Only relevant when `readOnlyHint` is `false`.
- `idempotentHint` (boolean, default `false`): If `true`, calling the tool multiple times with the same arguments has the same effect as calling it once.
- `openWorldHint` (boolean, default `true`): If `true`, the tool may interact with external systems or the environment.

Annotations help clients present appropriate UI cues (e.g., confirmation dialogs for destructive tools).

Metadata precedence order:
1. `<tool>.meta.json`
2. Inline `# mcp:` annotations (JSON payload)
3. Defaults (empty `arguments`, no `outputSchema`)

## `.registry/resources.json`

Entries describe resource templates and providers. Paths are relative to `MCPBASH_RESOURCES_DIR`.

```json
{
  "version": 1,
  "generatedAt": "2025-10-18T09:00:00Z",
  "items": [
    {
      "name": "file-readme",
      "description": "Serve README fragments",
      "path": "readme/README.md",
      "uri": "file:///path/to/project/resources/readme/README.md",
      "mimeType": "text/markdown",
      "provider": "file",
      "icons": [
        {"src": "https://example.com/doc-icon.png", "mimeType": "image/png", "sizes": ["48x48"]}
      ]
    }
  ],
  "hash": "77b2e6fa5b2986a2b9ac64a2f1c6b757b954dcbe356743f9fb493144b917ebc7",
  "total": 1
}
```

- Metadata that cannot be parsed (missing `uri`, unsupported `provider`, non-object `arguments`, unreadable `.meta.json`) is skipped and logged as a warning through the structured logging subsystem.
- When no `provider` is specified, the scanner infers one from the URI scheme (`file://`, `git://`, `https://`); unrecognised schemes default to `file` and are rejected if the provider script is unavailable.
- Discovery records `name`, `description`, `path`, `uri`, `mimeType`, and `provider`; argument/template schemas are not persisted today.
- The `file` provider fails closed if no resource roots are configured; missing/non-existent roots are ignored, so ensure allowed roots exist before use.
- Subscription notifications include both `subscriptionId` and a nested `subscription` object (`{id, uri}`) for client convenience; MCP allows additional fields, and clients that only look at `subscriptionId` remain compatible.

## Resource Templates

The MCP protocol supports **resource templates** — parameterized resources using [RFC 6570 URI templates](https://datatracker.ietf.org/doc/html/rfc6570) (e.g., `file:///{path}`, `logs/{date}.log`). Templates allow servers to expose dynamic access patterns without enumerating every possible resource.

**Current status:** The `resources/templates/list` endpoint is implemented and returns a valid, paginated empty response. Template discovery from `.meta.json` files (using `uriTemplate` instead of `uri`) is not yet implemented, and the capability is not advertised until discovery is added.

**Response format:**

```json
{
  "resourceTemplates": [],
  "nextCursor": null
}
```

When template discovery is implemented, entries will follow the MCP schema:

```json
{
  "name": "project-files",
  "uriTemplate": "file:///{path}",
  "description": "Access any file in the project directory",
  "mimeType": "application/octet-stream"
}
```

**Note:** Resource templates are for discovery only. Clients expand the URI template with their own values and call `resources/read` with the resulting concrete URI.

## `.registry/prompts.json`

Entries reference prompt templates and metadata. Paths are relative to `MCPBASH_PROMPTS_DIR`.

```json
{
  "version": 1,
  "generatedAt": "2025-10-18T09:00:00Z",
  "items": [
    {
      "name": "summarise-notes",
      "description": "Summarise meeting notes",
      "path": "summarise/summarise.txt",
      "arguments": {
        "type": "object",
        "required": ["notes"],
        "properties": {
          "notes": {
            "type": "string"
          }
        }
      },
      "icons": [
        {"src": "https://example.com/summary-icon.svg", "mimeType": "image/svg+xml"}
      ]
    }
  ],
  "hash": "a46db88ec044b6bfc28f0c30a8243f005f7947743104c1d343958aa88f76768a",
  "total": 1
}
```

- Malformed prompt metadata (e.g., unreadable `.meta.json`, non-object `arguments`, unsupported `metadata` fields) is skipped and surfaced via structured warnings through the logging subsystem.
- Optional `role` and `metadata` properties discovered during scanning are preserved for downstream rendering.

## TTL and Regeneration

- TTL defaults to five seconds (`MCP_TOOLS_TTL`, etc.).
- Registry files refresh when TTL expires. Fast-path detection (directory mtime, file count, and file-path hash) skips expensive rebuilds when nothing changed; a detected change triggers a rebuild and list_changed notifications (for clients that negotiated support).
- Manual refresh: `bin/mcp-bash registry refresh [--project-root DIR] [--no-notify] [--filter PATH]` rebuilds `.registry/*.json` and emits a status JSON. `--project-root` runs offline without notifications; `--filter` narrows scanning to a subpath when trees are very large.
- Manual overrides (`server.d/register.sh`) can replace the auto-discovery results entirely.
- Cached files are ignored if their size exceeds the configured limit or if JSON parsing fails, forcing a rescan on next access.

Additional discovery rules (depth limits, hidden directory exclusion, manual registration hooks) live with the discovery scripts and comments inside this repository.
