# Resource Templates

Resource templates advertise families of resources using RFC 6570 URI templates (e.g., `file:///{+path}`, `git+https://{repo}/{ref}/{+path}`). Clients call `resources/templates/list`, expand a template themselves, and pass the concrete URI to `resources/read`. The server matches that URI back to its template (see [Reading expanded URIs](#reading-expanded-uris)), so the template's `mimeType` applies and the provider learns which template and values matched. Use `{+path}` for a value that spans `/`: a plain `{path}` stops at the first `/`.

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
  "uriTemplate": "file:///{+path}",
  "description": "Access any file in the project directory",
  "annotations": {"audience": ["user", "assistant"]}
}
```
Discovery scans `resources/*.meta.json`, requires `uriTemplate` to be a string with at least one `{variable}`, and skips entries that also set `uri`.

Set `mimeType` on a template only if every match has that type. A catch-all such as `file:///{+path}` matches files of every type, so it should leave `mimeType` out.

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

`resources/read` looks a URI up in this order:

1. By `name`, when the request has one.
2. By exact URI among the static resources.
3. Against the resource templates (below).
4. By scheme, to pick the provider. Step 3 does not change this.

### Matching a URI to a template

Only a strict subset of RFC 6570 is matched:

| Expression | Matches |
| --- | --- |
| `{v}` | one or more characters, never `/`, `?` or `#` |
| `{+v}` | one or more characters, `/` included |
| `{#v}` | a literal `#`, then as `{+v}` |

- Variable names are `[A-Za-z0-9_]+` and may appear only once per template.
- Some templates are never matched:
  - any other operator: `{/v}`, `{?q}`, `{&q}`, `{;p}`, `{.e}`;
  - a comma list: `{a,b}`;
  - a modifier: `{v*}`, `{v:3}`;
  - two expressions side by side: `{a}{b}`.

  Such a template is still listed by `resources/templates/list`, and reads of its URIs behave as if no template matched.
- Matching is exact and case-sensitive, character by character (Unicode codepoints). A value is never empty.
- When a variable could take several lengths, the leftmost variable takes the shortest value that still lets the rest of the template match. So `x://{+a}/{+b}` reads `x://p/q/r` as `a=p`, `b=q/r`.
- URIs longer than 2048 characters, or containing control characters or whitespace, are not matched.

When several templates match, the winner is the one with:

1. the most literal characters (the `#` of `{#v}` counts);
2. then the fewest expressions;
3. then the lowest `name`, in ascending order.

### What a match changes

- **`mimeType` is a declared label.** If the matched template sets `mimeType`, the response reports it. The content itself still decides whether it is sent as `text` or as a base64 `blob`. Without a template `mimeType`, the type is detected as before. Set `mimeType` on a template only if every URI it matches shares that type.
- **Provider environment.** The provider gets two extra variables:
  - `MCP_RESOURCE_TEMPLATE_NAME`: the matched template's `name`;
  - `MCP_RESOURCE_TEMPLATE_VARS`: a compact JSON object of the matched values, for example `{"id":"42","rest":"a/b%2Fc"}`.

  Neither is set on any other read, nor for tools or completion providers. The server clears any value the host set for them at startup.
- **The values are raw.** They are the characters from the URI, not percent-decoded. Decode them yourself if you need to, and validate the result: `%2F` decodes to `/` and `%2E%2E` to `..`, so a decoded `{v}` can still reach another path.

`$1` is still the full URI, so providers that parse it themselves keep working.

### Which provider runs

A match never changes which provider runs. The provider is inferred from the URI scheme:

- `file://`, `git+https://`, `https://` and `ui://` use the built-in providers.
- Any other scheme uses the project provider of the same name: `myapi://items/{id}` uses `providers/myapi.sh`.

That routing applies only to schemes the project declares. A scheme is declared by a template whose `uriTemplate` starts with that literal scheme, or by a static resource with that scheme and `"provider"` set to it. A template that is never matched (above) still declares its scheme. Scheme and file name are compared exactly, including case. A URI with an undeclared scheme is not sent to a project provider, even if a script of that name exists.

Declarations follow the registry cache. A removed template stops counting after the TTL, or, in static registry mode, after the cache is rebuilt.

## Security notes

- Templates do not bypass roots: `resources/read` still enforces configured roots for the expanded URI.
- Broad templates like `file:///{+path}` should be paired with tight roots and reviewed for path traversal and symlink handling in your providers.
- Treat `MCP_RESOURCE_TEMPLATE_VARS` like `$1`: it is client-supplied. Validate each value after any decoding.
