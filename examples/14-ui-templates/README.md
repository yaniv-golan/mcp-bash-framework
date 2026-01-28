# Example 14: System Dashboard

This example demonstrates how to display tool results in a rich UI dashboard using MCP Apps.

## What This Shows

- **Result-driven UI**: The UI displays data returned by the tool (not input forms)
- **Progress bars**: Visual representation of memory and disk usage percentages
- **Responsive design**: Adapts to light/dark mode and screen size
- **Real-time display**: UI updates when tool result is received

## Structure

```
examples/14-ui-templates/
├── README.md
├── server.meta.json
└── tools/
    └── system-info/
        ├── tool.sh           # Gathers system info (CPU, memory, disk)
        ├── tool.meta.json    # Tool metadata with UI resource reference
        └── ui/
            ├── index.html    # Dashboard HTML with SDK integration
            └── ui.meta.json  # UI metadata (CSP, preferences)
```

## How It Works

1. User (or Claude) calls the `system-info` tool
2. Tool runs shell commands (`uptime`, `vm_stat`/`free`, `df`) to gather system stats
3. Tool returns structured JSON with CPU load, memory usage, disk usage
4. MCP host displays the tool's UI resource
5. UI receives the tool result via `app.ontoolresult` callback
6. Dashboard renders the data with progress bars and cards

## Running

```bash
cd examples/14-ui-templates
mcp-bash serve
```

Or add to Claude Desktop config:

```json
{
  "mcpServers": {
    "system-dashboard": {
      "command": "/path/to/mcp-bash",
      "env": {
        "MCPBASH_PROJECT_ROOT": "/path/to/examples/14-ui-templates",
        "MCPBASH_TOOL_ALLOWLIST": "*"
      }
    }
  }
}
```

## Key Concepts

### Tool Returns Data, UI Displays It

This is the recommended pattern for mcp-bash:
- Tool does the work (runs commands, processes data)
- Tool returns structured JSON
- UI is a passive display that renders the result

### SDK Integration

The UI uses the MCP Apps SDK to receive tool results:

```javascript
import { App } from 'https://cdn.jsdelivr.net/npm/@modelcontextprotocol/ext-apps/+esm';

const app = new App({ name: "System Dashboard", version: "1.0.0" });

app.ontoolresult = (result) => {
  // result.structuredContent contains the tool's JSON output
  renderDashboard(result.structuredContent);
};

await app.connect();
```

### Cross-Platform Support

The tool.sh script handles both macOS and Linux:
- macOS: Uses `vm_stat`, `sysctl`, `sw_vers`
- Linux: Uses `free`, `/etc/os-release`
