# Resource Templates

Resource templates advertise families of resources using RFC 6570 URI templates (e.g., `file:///{path}`, `git+https://{repo}/{ref}/{path}`). The server **does not expand templates**; clients call `resources/templates/list`, expand the template client-side, then pass the concrete URI to `resources/read`.

## Discoverability (capabilities)

The MCP schema defines the `resources/templates/list` method, but server capabilities do **not** include a dedicated “templates supported” flag under `capabilities.resources`. Clients should treat templates as discoverable by probing the method:

- Call `resources/templates/list`.
- If the server returns `-32601` (method not found), treat templates as unsupported.
- If it succeeds (even with an empty `resourceTemplates` array), templates are supported.

## Auto-discovery (`resources/*.meta.json`)

Add `uriTemplate` to a resource meta file (omit `uri`):
```json
// resources/files.meta.json
{
  "name": "project-files",
  "title": "Project Files",
  "uriTemplate": "file:///{path}",
  "description": "Access any file in the project directory",
  "mimeType": "application/octet-stream",
  "annotations": {"audience": ["user", "assistant"]}
}
```
Discovery scans `resources/*.meta.json`, requires `uriTemplate` to be a string with at least one `{variable}`, and skips entries that also set `uri`.

## Declarative registration (`server.d/register.json`)

Register templates without executing shell code during list/refresh flows:

```json
// server.d/register.json
{
  "version": 1,
  "resourceTemplates": [
    {
      "name": "logs-by-date",
      "title": "Log Files by Date",
      "uriTemplate": "file:///var/log/{service}/{date}.log",
      "description": "Access log files by service and date"
    }
  ]
}
```

If `server.d/register.json` is present, it takes precedence over `server.d/register.sh` (no fallback on validation errors). See [REGISTRY.md](REGISTRY.md) for the full schema and strictness rules.

## Hook registration (`server.d/register.sh`)

Manual templates merge on top of auto-discovered entries (manual wins on name collisions):
```bash
mcp_resources_templates_manual_begin
mcp_resources_templates_register_manual '{
  "name": "logs-by-date",
  "title": "Log Files by Date",
  "uriTemplate": "file:///var/log/{service}/{date}.log",
  "description": "Access log files by service and date"
}'
mcp_resources_templates_manual_finalize
```

Alternatively, emit a bulk JSON payload with `resourceTemplates` to stdout; the manual registry pipeline will parse it.

## Validation and merge rules

- `uriTemplate` **required** and must include `{variable}`; `{}` or `{   }` are rejected.
- `uri` and `uriTemplate` are mutually exclusive; mixed entries are skipped with a warning.
- Names must be unique; duplicates keep the first entry within each source, and manual entries override auto-discovered ones.
- Templates cannot reuse a resource name; conflicts are skipped.
- Optional fields (`title`, `description`, `mimeType`, `annotations`, `_meta`) pass through verbatim.
- Registry cache: `.registry/resource-templates.json`, hash based on the merged item list; TTL set by `MCP_RESOURCES_TEMPLATES_TTL` (default 5s).

## Listing and notifications

- `resources/templates/list` supports `limit` (default 50, max 200) and exposes the full count as an extension via `result._meta["mcpbash/total"]` alongside `resourceTemplates` and `nextCursor` (cursor uses the templates registry hash; stale cursors return `-32602`).
- Template changes set the shared `MCP_RESOURCES_CHANGED` flag and trigger `notifications/resources/list_changed`, so clients can re-fetch resources **and** templates.

## Reading expanded URIs

Template metadata is not consulted by `resources/read`. The provider for an expanded URI is inferred from its scheme: `file://`, `git+https://`, `https://` and `ui://` use the built-in providers, and any other scheme uses the project provider of the same name (`myapi://items/{id}` → `providers/myapi.sh`). That routing applies only to schemes the project declares: a template whose `uriTemplate` starts with the literal scheme, or a static resource with that scheme and `"provider"` set to it. Scheme and file name are compared exactly, including case. A URI with an undeclared scheme is not sent to a project provider, even if a script of that name exists. Declarations follow the registry cache, so a removed template stops counting after the TTL, or in static registry mode after the cache is rebuilt. The provider receives the concrete URI as `$1` and parses the variables itself. The template's `mimeType` is not applied to the response, so the content is reported as `text/plain`.

## Security notes

- Templates do not bypass roots: `resources/read` still enforces configured roots for the expanded URI.
- Broad templates like `file:///{path}` should be paired with tight roots and reviewed for path traversal and symlink handling in your providers.
