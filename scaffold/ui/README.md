# __NAME__ UI

This is a standalone UI resource for the MCP server.

## Files

- `index.html` - The HTML interface
- `ui.meta.json` - UI metadata (CSP, permissions)

## Usage

This UI is served at `ui://<server-name>/__NAME__`.

### Tool-Associated UI (Automatic)

If this UI is inside a tool directory (`tools/<tool>/ui/`), the framework automatically links them - no configuration needed.

### Standalone UI (Manual)

For standalone UIs in `ui/`, manually link to a tool by adding to `tools/<tool>/tool.meta.json`:

```json
{
  "_meta": {
    "ui": {
      "resourceUri": "ui://<server-name>/__NAME__"
    }
  }
}
```

## Development

See [UI Resources Guide](https://github.com/yaniv-golan/mcp-bash-framework/blob/main/docs/guides/ui-resources.md).

## CSP Notes

The inline `<script type="module">` works in Claude Desktop and other MCP hosts that sandbox UI in iframes. For strict CSP environments, consider moving JavaScript to an external file.
