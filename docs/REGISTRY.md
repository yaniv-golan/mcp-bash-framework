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

```json
{
  "version": 1,
  "generatedAt": "2025-10-18T09:00:00Z",
  "items": [
    {
      "name": "example.hello",
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
      "timeoutSecs": 5
    }
  ],
  "hash": "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945",
  "total": 1
}
```

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
      "name": "file.readme",
      "description": "Serve README fragments",
      "path": "readme/README.md",
      "uri": "file:///path/to/project/resources/readme/README.md",
      "mimeType": "text/markdown",
      "provider": "file"
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
      "name": "summarise.notes",
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
      }
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
