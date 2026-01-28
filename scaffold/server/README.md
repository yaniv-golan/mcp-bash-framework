# Server Metadata

Place `server.meta.json` in your project's `server.d/` directory to customize server identity.

## Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | No | Server identifier (default: project directory name) |
| `title` | No | Human-readable display name (default: titlecase of name) |
| `version` | No | Server version (default: from VERSION file, package.json, or "0.0.0") |
| `description` | No | Brief description of the server |
| `websiteUrl` | No | URL to server homepage or documentation |
| `icons` | No | Array of icon objects for visual identification |

## Icons Format

```json
{
  "icons": [
    {
      "src": "https://example.com/icon.png",
      "sizes": ["48x48"],
      "mimeType": "image/png"
    },
    {
      "src": "https://example.com/icon.svg",
      "sizes": ["any"],
      "mimeType": "image/svg+xml"
    }
  ]
}
```

## Smart Defaults

If `server.meta.json` is not present or fields are omitted, smart defaults are applied:

- **name**: `basename` of your project directory (e.g., `/home/user/my-server` → `my-server`)
- **title**: Titlecase of name (e.g., `my-server` → `My Server`)
- **version**: Reads from `VERSION` file, then `package.json`, else `0.0.0`

## Example

For a project at `/home/user/weather-api/` with no `server.meta.json`:

```json
{
  "name": "weather-api",
  "title": "Weather Api",
  "version": "0.0.0"
}
```

## UI Resources

This server can provide HTML interfaces to MCP clients that support MCP Apps.
See [UI Resources Guide](https://github.com/yaniv-golan/mcp-bash-framework/blob/main/docs/guides/ui-resources.md).

