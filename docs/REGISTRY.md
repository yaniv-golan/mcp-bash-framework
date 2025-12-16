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
- `total`: Count of `items`. For list methods (`tools/list`, `resources/list`, `prompts/list`, `resources/templates/list`), this count is exposed as an extension via `result._meta["mcpbash/total"]` (not as a top-level result field) for strict-client compatibility.

Guardrails are enforced for all registries:

- When `total > 500`, the server logs a warning suggesting manual registration.
- If the serialised registry exceeds `MCPBASH_REGISTRY_MAX_BYTES` (default 100 MB), the scan aborts with `-32603`.

## `.registry/tools.json`

Each entry describes an executable tool. Paths are relative to `MCPBASH_TOOLS_DIR`.
Tool names must match `^[a-zA-Z0-9_-]{1,64}$`; some clients, including Claude Desktop, enforce this and reject dotted names, so prefer hyphenated or underscored namespaces.

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

Entries describe resources and providers. Paths are relative to `MCPBASH_RESOURCES_DIR`.

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
- When no `provider` is specified, the scanner infers one from the URI scheme (`file://`, `git+https://`, `https://`); unrecognised schemes default to `file` and are rejected if the provider script is unavailable.
- Discovery records `name`, `description`, `path`, `uri`, `mimeType`, and `provider`; argument/template schemas are not persisted today.
- The `file` provider fails closed if no resource roots are configured; missing/non-existent roots are ignored, so ensure allowed roots exist before use.
- Subscription notifications (`notifications/resources/updated`) are spec-shaped and only include `params.uri`; clients should call `resources/read` to fetch the updated content.

## `.registry/resource-templates.json`

Entries describe resource template patterns, sorted by `name`, and are refreshed independently of static resources.

```json
{
  "version": 1,
  "generatedAt": "2025-12-09T10:00:00Z",
  "items": [
    {
      "name": "project-files",
      "uriTemplate": "file:///{path}",
      "title": "Project Files",
      "description": "Access any file in the project",
      "mimeType": "application/octet-stream"
    },
    {
      "name": "logs-by-date",
      "uriTemplate": "file:///var/log/{service}/{date}.log",
      "description": "Log files by service and date"
    }
  ],
  "hash": "abc123...",
  "total": 2
}
```

Registry fields mirror the MCP `ResourceTemplate` schema, plus `generatedAt`, `hash`, and `total`.

## Resource Templates

The MCP protocol supports **resource templates** — parameterized resources using [RFC 6570 URI templates](https://datatracker.ietf.org/doc/html/rfc6570) (e.g., `file:///{path}`, `logs/{date}.log`). Templates expose families of URIs without enumerating every instance.

Key behaviors:
- Auto-discovery scans `resources/*.meta.json` for `uriTemplate` (string) and ignores entries with `uri` set. If both are present, the entry is skipped with a warning.
- `uriTemplate` must contain at least one `{variable}` (server policy to catch static URIs).
- Template names may not collide with resource names; conflicts are skipped with a warning. Manual templates override auto-discovered templates that share a name.
- Discovery results are cached in `.registry/resource-templates.json` with hash-based pagination. TTL is controlled via `MCP_RESOURCES_TEMPLATES_TTL` (default 5s).
- Changes to templates trigger the existing `notifications/resources/list_changed` path (`MCP_RESOURCES_CHANGED` flag is shared with resources).
- `resources/templates/list` supports the same `limit` extension as other list endpoints and exposes the full count via `result._meta["mcpbash/total"]`; cursor decoding uses the templates registry hash so stale cursors are rejected after changes.

## Declarative registration (`server.d/register.json`)

Projects can register tools/resources/prompts/resource templates/completions via a **data-only** file at `server.d/register.json`. This avoids executing project shell code during list/refresh flows.

- **Precedence**: if `server.d/register.json` exists, it is used instead of `server.d/register.sh`. If `register.json` is invalid, the server fails loudly and does **not** fall back to executing `register.sh`.
- **Version**: requires `"version": 1`.
- **Strictness**:
  - standard JSON only (no comments/JSON5)
  - UTF-8 required; **no BOM**
  - unknown top-level keys are rejected (except optional `_meta`)
  - for each kind, a present key must be an array (or `null`)
- **Per-kind semantics**:
  - key **absent** or `null`: fall through to auto-discovery for that kind
  - key present with `[]`: explicitly disables that kind (no scan)
- **Size limit**: file size is capped by `MCPBASH_MAX_MANUAL_REGISTRY_BYTES` (default 1 MiB).

Top-level schema:

```json
{
  "version": 1,
  "tools": [],
  "resources": [],
  "resourceTemplates": [],
  "prompts": [],
  "completions": []
}
```

## Hook registration (`server.d/register.sh`)

Manual registration in `server.d/register.sh` mirrors the tools/resources pattern (only runs when `MCPBASH_ALLOW_PROJECT_HOOKS=true` and the script is owned by the current user with safe permissions):
```bash
mcp_resources_templates_manual_begin
mcp_resources_templates_register_manual '{"name":"logs-by-date","uriTemplate":"file:///var/log/{service}/{date}.log"}'
mcp_resources_templates_manual_finalize
```
Manual entries pass through the same validators as auto-discovery and are merged on top of discovered templates (manual wins). Script output can also provide a `resourceTemplates` array for bulk registration.

See `examples/advanced/register-sh-hooks/` for a concrete hook-based setup (dynamic registration; opt-in; avoid side effects).

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
