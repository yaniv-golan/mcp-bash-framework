# MCP Apps Overview

MCP Apps is an extension to the Model Context Protocol that enables servers to deliver interactive user interfaces to host applications. This allows tools to return rich UI components—dashboards, forms, visualizations, multi-step workflows—that render directly in conversations.

> **Official Specification**: [MCP Apps Extension (Stable, 2026-01-26)](https://modelcontextprotocol.io/specification/2025-03-26/extensions/apps)
>
> This document describes mcp-bash's implementation of the spec, plus convenience features we've added on top.

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         MCP Host                                 │
│  (Claude Desktop, Cursor, ChatGPT, etc.)                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   1. tools/list ───────────────►  MCP Server                    │
│      (get tool definitions)         │                           │
│   1b. Tool with _meta.ui ◄──────────┘                           │
│                                                                  │
│   2. Tool Call ────────────────►  MCP Server                    │
│      (execute tool)                 │                           │
│   2b. Result (data only) ◄──────────┘                           │
│                                                                  │
│   3. Fetch ui:// resource ─────►  MCP Server                    │
│      (from _meta.ui.resourceUri)    │                           │
│   3b. HTML content ◄────────────────┘                           │
│                                                                  │
│   4. Render HTML + send tool data to iframe                     │
│                                                                  │
│   5. UI ◄────JSON-RPC────► Host ◄────MCP────► Server           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Flow Summary

1. **Tool Discovery**: Host fetches `tools/list` and sees tool has `_meta.ui.resourceUri`
2. **Tool Call**: Host calls the tool; server returns result data (no `_meta.ui` needed in result)
3. **Resource Fetch**: Host requests the UI resource via `resources/read` (URI from tool definition)
4. **HTML Delivery**: Server returns HTML with MIME type `text/html;profile=mcp-app`
5. **Rendering**: Host renders HTML in sandboxed iframe, sends tool result via notification
6. **Communication**: UI communicates with host via JSON-RPC (MCP Apps SDK)

## Key Concepts

### UI Resources

UI resources are HTML pages that can be served to MCP clients. They use the `ui://` URI scheme:

```
ui://[server-name]/[resource-name]
```

Examples:
- `ui://weather-server/dashboard`
- `ui://xaffinity-mcp/query-builder`

### Capability Negotiation

Clients advertise UI support during initialization:

```json
{
  "capabilities": {
    "extensions": {
      "io.modelcontextprotocol/ui": {
        "mimeTypes": ["text/html;profile=mcp-app"]
      }
    }
  }
}
```

Servers should check for UI support before registering UI-enabled tools:

```bash
if mcp_client_supports_ui; then
  # Register UI-enabled tools
fi
```

### Tool Metadata

Tools reference UI resources via `_meta.ui`:

```json
{
  "name": "query",
  "description": "Execute queries with visual results",
  "inputSchema": { ... },
  "_meta": {
    "ui": {
      "resourceUri": "ui://server/query-results",
      "visibility": ["model", "app"]
    }
  }
}
```

**Visibility Options:**
- `"model"`: Agent can see and call the tool (default)
- `"app"`: UI can call the tool (default)
- Omitting `"model"` hides tool from agent (UI-only)

### Resource Response

UI resources are delivered via `resources/read`:

```json
{
  "contents": [{
    "uri": "ui://server/resource",
    "mimeType": "text/html;profile=mcp-app",
    "text": "<!DOCTYPE html>...",
    "_meta": {
      "ui": {
        "csp": {
          "connectDomains": ["api.example.com"],
          "resourceDomains": ["cdn.example.com"],
          "frameDomains": [],
          "baseUriDomains": []
        },
        "permissions": {},
        "prefersBorder": true
      }
    }
  }]
}
```

## Security Model

1. **Iframe Sandboxing**: `allow-scripts allow-same-origin` only
2. **CSP Enforcement**: Hosts construct CSP from declared domains
3. **Predeclared Resources**: All UI resources known at connection time
4. **Auditable Messages**: All JSON-RPC logged
5. **User Consent**: Required for UI-initiated tool calls

### Content Security Policy (CSP)

UIs must declare required domains:
- `connectDomains`: APIs the UI needs to call (WebSocket, fetch)
- `resourceDomains`: CDNs for fonts, images, media
- `frameDomains`: Allowed embedded iframes
- `baseUriDomains`: Allowed base URI values

## MCP Apps SDK

UIs communicate with the host using the official MCP Apps SDK:

```html
<script type="module">
  import { App } from 'https://cdn.jsdelivr.net/npm/@modelcontextprotocol/ext-apps/+esm';

  // Create app instance with metadata
  const app = new App({ name: "My App", version: "1.0.0" });

  // Set handler BEFORE connect() to avoid missing initial result
  app.ontoolresult = (result) => {
    // result.structuredContent - UI-optimized data
    // result.content - text representation
    console.log('Received result:', result);
  };

  // Connect to host
  await app.connect();

  // Call server tools (after connect)
  const result = await app.callServerTool({ name: 'my-tool', arguments: { arg: 'value' } });

  // Send messages to chat
  app.sendMessage({ role: 'user', content: { type: 'text', text: 'Operation completed' } });
</script>
```

### Available Methods

| Method | Purpose |
|--------|---------|
| `app.connect()` | Establish connection to host |
| `app.getHostContext()` | Get theme, display mode, dimensions |
| `app.callServerTool({ name, arguments })` | Execute a server tool |
| `app.sendMessage({ role, content })` | Send message to chat |
| `app.readResource(uri)` | Read a server resource |
| `app.requestDisplayMode(mode)` | Request inline/fullscreen/pip |

### Event Handlers

| Property | Purpose |
|----------|---------|
| `app.ontoolresult` | Receives tool execution results |
| `app.ontoolinput` | Receives tool arguments (before result) |
| `app.onhostcontextchanged` | Theme/display mode changes |

## Theming

MCP Apps defines 80+ CSS custom properties for consistent theming:

```css
/* Colors */
--color-background-primary
--color-text-primary
--color-border-primary

/* Typography */
--font-sans
--font-mono
--font-text-md-size

/* Spacing and radius */
--border-radius-md
--shadow-sm
```

UIs using these variables automatically adapt to light/dark mode.

## Display Modes

UIs can request different display modes:

| Mode | Description | Use Case |
|------|-------------|----------|
| `inline` | Embedded in conversation (default) | Simple forms, status |
| `fullscreen` | Full viewport | Complex dashboards |
| `picture-in-picture` | Floating overlay | Persistent monitoring |

## mcp-bash Implementation

### Spec Implementation (Required by MCP Apps)

These features implement the official specification:

| Feature | Description |
|---------|-------------|
| `ui://` resources | Serve HTML via `resources/read` with `text/html;profile=mcp-app` |
| `_meta.ui` in tools | Tool definitions include `resourceUri` and `visibility` |
| `_meta.ui` in resources | CSP configuration, permissions, prefersBorder |
| Capability negotiation | Detect client UI support via `extensions` capability |
| CSP domains | `connectDomains`, `resourceDomains`, `frameDomains`, `baseUriDomains` |

### mcp-bash Convenience Features (Our Additions)

These features are **not part of the spec** - they're mcp-bash conveniences to make UI development easier in pure Bash:

| Feature | Description |
|---------|-------------|
| **Auto-discovery** | Scan `tools/*/ui/` and `ui/*/` directories automatically |
| **Templates** | Generate HTML from JSON config (`form`, `data-table`, `progress`, etc.) |
| **ui.meta.json** | Declarative metadata file instead of code |
| **SDK helpers** | Bash functions like `mcp_ui_get_content()`, `mcp_ui_build_csp()` |
| **Template caching** | Performance optimization for generated HTML |

The spec only requires serving HTML - how you generate that HTML is up to you. Templates are our solution for Bash environments without JS build tools.

See:
- [UI Resources Guide](../guides/ui-resources.md) - How to add UI to tools
- [UI Templates Reference](../reference/ui-templates.md) - Template configuration (mcp-bash specific)
- [UI SDK Reference](../reference/ui-sdk.md) - Bash helper functions (mcp-bash specific)

## References

- [MCP Apps Extension Specification](https://modelcontextprotocol.io/specification/2025-03-26/extensions/apps) - Official stable spec
- [MCP Apps SDK](https://www.npmjs.com/package/@modelcontextprotocol/ext-apps) - JavaScript SDK for UI ↔ host communication
- [MCP Protocol Specification](https://modelcontextprotocol.io/specification) - Core MCP spec
