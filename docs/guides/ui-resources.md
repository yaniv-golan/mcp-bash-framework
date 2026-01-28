# UI Resources Guide

This guide explains how to create and serve UI resources with mcp-bash.

> **Specification**: This implements the [MCP Apps Extension](https://modelcontextprotocol.io/specification/2025-03-26/extensions/apps). The spec defines `ui://` resources, `_meta.ui` metadata, and CSP configuration. mcp-bash adds convenience features like auto-discovery and templates on top.

## Overview

UI resources are HTML pages that can be rendered in MCP clients that support the MCP Apps extension. mcp-bash supports two approaches:

1. **Static HTML**: Write your own HTML/CSS/JS (spec-compliant)
2. **Templates**: Generate HTML from JSON configuration (mcp-bash convenience)

## Quick Start with Scaffold

The fastest way to add UI to your project is using the scaffold commands:

### Tool-Associated UI (Recommended)

Create a tool with UI in one command:

```bash
mcp-bash scaffold tool weather --ui
```

This creates:
- `tools/weather/tool.sh` - Tool implementation
- `tools/weather/tool.meta.json` - Tool metadata
- `tools/weather/ui/index.html` - UI template with MCP Apps SDK
- `tools/weather/ui/ui.meta.json` - UI metadata with CSP

The framework **automatically links** the UI to the tool - no manual configuration needed.

### Add UI to Existing Tool

```bash
mcp-bash scaffold ui --tool weather
```

Creates `tools/weather/ui/` with the UI template. The name defaults to the tool name.

### Standalone UI (Dashboards, Monitors)

For UIs not tied to a specific tool:

```bash
mcp-bash scaffold ui dashboard
```

Creates `ui/dashboard/` with UI files. Standalone UIs require **manual linking** - add `_meta.ui` to the tool that should display them:

```json
{
  "_meta": {
    "ui": {
      "resourceUri": "ui://my-server/dashboard"
    }
  }
}
```

### When to Use Each Pattern

| Pattern | Command | Use Case |
|---------|---------|----------|
| **Tool + UI** | `scaffold tool <name> --ui` | New tool that displays results visually |
| **UI for existing tool** | `scaffold ui --tool <name>` | Add UI to a tool you already created |
| **Standalone UI** | `scaffold ui <name>` | Server-wide dashboards, monitors, settings |

## Directory Structure

### Tool-Associated UI

Place UI resources alongside tools:

```
tools/
└── weather/
    ├── tool.sh
    ├── tool.meta.json
    └── ui/
        ├── index.html        # Static HTML (required if no template)
        └── ui.meta.json      # UI metadata (required if using templates)
```

> **Note**: At least one of `index.html` or `ui.meta.json` must exist for auto-linking to work.

### Standalone UI

Place UI resources in the `ui/` directory:

```
ui/
└── dashboard/
    ├── index.html
    └── ui.meta.json
```

## Automatic Tool-UI Linking

When a tool has a `ui/` subdirectory with content (`index.html` or `ui.meta.json`), mcp-bash automatically links them:

```
tools/
└── weather/
    ├── tool.sh
    ├── tool.meta.json      # No _meta.ui needed!
    └── ui/
        ├── index.html
        └── ui.meta.json
```

The framework auto-generates `_meta.ui` in the tool definition sent to clients:

```json
"_meta": {
  "ui": {
    "resourceUri": "ui://{server-name}/weather",
    "visibility": ["model", "app"]
  }
}
```

The `{server-name}` comes from your `server.d/server.meta.json`:

```json
{
  "name": "my-server",
  ...
}
```

### Overriding Defaults

To use a different UI resource or custom visibility, add explicit `_meta.ui` to `tool.meta.json`:

```json
{
  "name": "weather",
  "_meta": {
    "ui": {
      "resourceUri": "ui://my-server/shared-dashboard",
      "visibility": ["app"]
    }
  }
}
```

## UI Metadata (ui.meta.json)

Every UI resource needs a `ui.meta.json` file:

```json
{
  "description": "Weather visualization dashboard",
  "entrypoint": "index.html",
  "meta": {
    "csp": {
      "connectDomains": ["api.weather.com"],
      "resourceDomains": ["cdn.weather.com"],
      "frameDomains": [],
      "baseUriDomains": []
    },
    "permissions": {},
    "prefersBorder": true
  }
}
```

### Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `description` | string | Auto-generated | Human-readable description |
| `entrypoint` | string | `"index.html"` | Main HTML file |
| `template` | string | - | Template to use (form, data-table, etc.) |
| `config` | object | `{}` | Template configuration |
| `meta.csp` | object | `{}` | Content Security Policy domains |
| `meta.permissions` | object | `{}` | Requested browser permissions |
| `meta.prefersBorder` | boolean | `true` | Whether host should show border |

## Static HTML UI

### Loading the MCP Apps SDK

mcp-bash uses [jsdelivr](https://cdn.jsdelivr.net) to load the official MCP Apps SDK directly in the browser without a build step:

```javascript
import { App } from 'https://cdn.jsdelivr.net/npm/@modelcontextprotocol/ext-apps/+esm';
```

**Why CDN instead of bundling?**

| Approach | Requires | Pros | Cons |
|----------|----------|------|------|
| **CDN** (mcp-bash) | Nothing | No build tools, pure Bash workflow | Runtime dependency |
| **Bundling** (official examples) | Node.js, Vite | No runtime dependency | Needs JS toolchain |

mcp-bash is a pure Bash framework - adding a JavaScript build step would contradict the "just write Bash" philosophy. For production deployments where you want to eliminate the CDN dependency, you can inline a bundled copy of the SDK.

**CSP requirement:** When using jsdelivr, add it to your `ui.meta.json`:
```json
{
  "meta": {
    "csp": {
      "connectDomains": ["https://cdn.jsdelivr.net"],
      "resourceDomains": ["https://cdn.jsdelivr.net"]
    }
  }
}
```

### Basic Example

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Weather Dashboard</title>
  <style>
    body {
      font-family: var(--font-sans, system-ui);
      padding: 16px;
      background: var(--color-background-primary, #fff);
      color: var(--color-text-primary, #1a1a1a);
    }
  </style>
</head>
<body>
  <h2>Weather Dashboard</h2>
  <div id="weather-data">Loading...</div>

  <script type="module">
    import { App } from 'https://cdn.jsdelivr.net/npm/@modelcontextprotocol/ext-apps/+esm';

    // Create app instance with metadata
    const app = new App({ name: "Weather Dashboard", version: "1.0.0" });

    // Set handler BEFORE connect() to avoid missing initial result
    app.ontoolresult = (result) => {
      // Prefer structuredContent (optimized for UI), fall back to content
      const data = result?.structuredContent ??
        JSON.parse(result?.content?.find(c => c.type === 'text')?.text || '{}');

      document.getElementById('weather-data').innerHTML = `
        <p>Temperature: ${data.temperature}°</p>
        <p>Condition: ${data.condition}</p>
      `;
    };

    // Connect to host
    await app.connect();
  </script>
</body>
</html>
```

### Using MCP CSS Variables

Always use MCP CSS variables for theming:

```css
/* Colors */
color: var(--color-text-primary, #1a1a1a);
background: var(--color-background-primary, #fff);
border-color: var(--color-border-primary, #ccc);

/* Typography */
font-family: var(--font-sans, system-ui);
font-size: var(--font-text-md-size, 14px);

/* Borders and shadows */
border-radius: var(--border-radius-md, 6px);
box-shadow: var(--shadow-sm, 0 1px 2px rgba(0,0,0,0.05));
```

## Template-Based UI

For common patterns, use templates instead of writing HTML:

### Form Template

```json
{
  "description": "Task creation form",
  "template": "form",
  "config": {
    "title": "Create Task",
    "description": "Fill in the task details",
    "fields": [
      {"name": "title", "type": "text", "label": "Title", "required": true},
      {"name": "priority", "type": "select", "label": "Priority", "options": ["low", "medium", "high"]},
      {"name": "description", "type": "textarea", "label": "Description"}
    ],
    "submitTool": "create-task",
    "submitArgs": {"project": "default"},
    "cancelable": true
  }
}
```

### Data Table Template

```json
{
  "description": "Query results table",
  "template": "data-table",
  "config": {
    "title": "Results",
    "columns": [
      {"key": "id", "label": "ID", "sortable": true},
      {"key": "name", "label": "Name", "sortable": true},
      {"key": "status", "label": "Status"}
    ]
  }
}
```

### Progress Template

```json
{
  "description": "Operation progress",
  "template": "progress",
  "config": {
    "title": "Processing",
    "showPercentage": true,
    "showCurrentStep": true,
    "cancelTool": "cancel-operation",
    "cancelConfirm": "Are you sure you want to cancel?"
  }
}
```

### Diff Viewer Template

```json
{
  "description": "Code diff viewer",
  "template": "diff-viewer",
  "config": {
    "title": "Changes",
    "viewMode": "split",
    "showLineNumbers": true,
    "syntaxHighlight": true,
    "leftTitle": "Original",
    "rightTitle": "Modified"
  }
}
```

### Tree View Template

```json
{
  "description": "File tree",
  "template": "tree-view",
  "config": {
    "title": "Project Files",
    "showIcons": true,
    "expandLevel": 2,
    "selectable": true,
    "onSelectTool": "open-file"
  }
}
```

### Kanban Template

```json
{
  "description": "Task board",
  "template": "kanban",
  "config": {
    "title": "Sprint Board",
    "columns": [
      {"id": "todo", "title": "To Do"},
      {"id": "in-progress", "title": "In Progress"},
      {"id": "done", "title": "Done"}
    ],
    "draggable": true,
    "onMoveTool": "update-task-status",
    "onCardClickTool": "open-task"
  }
}
```

## Linking Tools to UI

For tool-associated UI (where `ui/` is inside the tool directory), linking is **automatic** - see [Automatic Tool-UI Linking](#automatic-tool-ui-linking) above.

### Manual Linking (Standalone UI)

For standalone UI resources in `ui/`, or to override the auto-generated link, add explicit `_meta.ui` to `tool.meta.json`:

```json
{
  "name": "query",
  "description": "Execute a database query",
  "inputSchema": {
    "type": "object",
    "properties": {
      "sql": {"type": "string"}
    }
  },
  "_meta": {
    "ui": {
      "resourceUri": "ui://my-server/query-results",
      "visibility": ["model", "app"]
    }
  }
}
```

### Tool Output Format

Per the MCP Apps spec, `_meta.ui` belongs in the tool **definition** (`tool.meta.json`), NOT in tool results. Tool results should include `content` for text representation and `structuredContent` for UI-optimized data:

```bash
#!/usr/bin/env bash
# tool.sh

# Do the work...
result='{"data": [{"id": 1, "name": "Test"}]}'

# Output result (UI resource is declared in tool.meta.json, not here)
cat <<EOF
{
  "content": [{"type": "text", "text": "Found 1 result"}],
  "structuredContent": ${result},
  "isError": false
}
EOF
```

The host reads `_meta.ui.resourceUri` from the tool definition to know which UI to render, then passes the tool result to that UI via the `ontoolresult` handler.

## Content Security Policy

### Declaring Domains

Specify required external domains in `ui.meta.json`:

```json
{
  "meta": {
    "csp": {
      "connectDomains": ["api.example.com", "ws.example.com"],
      "resourceDomains": ["cdn.example.com", "fonts.googleapis.com"],
      "frameDomains": ["embed.example.com"],
      "baseUriDomains": []
    }
  }
}
```

### Generated CSP

mcp-bash generates CSP headers automatically:

```
default-src 'self';
script-src 'self' https://cdn.jsdelivr.net;
style-src 'self' 'unsafe-inline';
connect-src 'self' api.example.com ws.example.com;
font-src 'self' cdn.example.com;
frame-src embed.example.com;
frame-ancestors 'none';
base-uri 'self'
```

## Permissions

Request browser permissions when needed:

```json
{
  "meta": {
    "permissions": {
      "clipboardWrite": {},
      "camera": {},
      "microphone": {},
      "geolocation": {}
    }
  }
}
```

Note: Permission availability depends on host capabilities.

## Testing UI Resources

### Manual Testing

1. Start your server with UI resources
2. Connect with an MCP client that supports UI
3. Call a tool that references UI
4. Verify UI renders correctly

### Using MCP Inspector

```bash
mcp-bash config --inspector
# Then call tools/read resources
```

### Unit Testing

See `test/unit/ui_*.bats` for examples.

## Troubleshooting

### UI Not Rendering

1. Check client supports UI extension
2. Verify `ui.meta.json` is valid JSON
3. Check console for JavaScript errors
4. Ensure MCP Apps SDK is loading

### CSP Errors

1. Check browser console for CSP violations
2. Add required domains to `meta.csp`
3. Verify domains are spelled correctly

### Tool Results Not Appearing

1. Verify tool output is valid JSON with `structuredContent` field
2. Check `_meta.ui.resourceUri` in `tool.meta.json` (not in tool result) matches UI path
3. Ensure `app.ontoolresult` handler is set BEFORE calling `app.connect()`
4. Delete `.registry/tools.json` cache to regenerate tool definitions

## Known Limitations

Due to current Claude Desktop implementation limitations:

- **Real-time progress updates**: UIs cannot receive `notifications/progress` during tool execution. The UI only receives `ontoolinput` when the tool starts and `ontoolresult` when it completes.

- **UI-initiated requests**: The MCP Apps SDK methods `callServerTool()` and `resources/read` are blocked by a [Claude Desktop bug](https://github.com/modelcontextprotocol/ext-apps/issues/386). UIs cannot poll for data or call other tools.

**Workarounds**:
- Use indeterminate progress (spinner) while waiting for results
- For multi-step operations, break into separate tool calls

## Examples

See the following example directories:

- `examples/13-ui-basics/` - Basic UI resource setup
- `examples/14-ui-templates/` - Template-based UIs

## Reference

- [MCP Apps Concepts](../concepts/mcp-apps.md)
- [UI Templates Reference](../reference/ui-templates.md)
- [UI SDK Reference](../reference/ui-sdk.md)
