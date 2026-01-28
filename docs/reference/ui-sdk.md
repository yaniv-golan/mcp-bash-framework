# UI SDK Reference

This document covers the Bash SDK functions for working with MCP Apps UI resources in mcp-bash.

> **Note**: These are **mcp-bash helper functions**, not part of the MCP Apps specification. The spec defines the protocol (capability negotiation, `_meta.ui` format, CSP fields) - these functions are our Bash implementation to make it easier to work with.

## Overview

The UI SDK consists of functions in three main areas:

1. **Capability Detection** - Check if client supports UI
2. **Resource Management** - Discover and serve UI resources
3. **CSP Generation** - Build Content Security Policy headers

## Files

| File | Purpose |
|------|---------|
| `lib/capabilities.sh` | Extension capability detection |
| `lib/ui.sh` | UI resource discovery and serving |
| `lib/ui-templates.sh` | Template-to-HTML generation |

---

## Capability Functions

### mcp_extensions_init

Initialize extension state from client capabilities.

```bash
mcp_extensions_init "$client_capabilities_json"
```

**Parameters:**
- `$1` - Client capabilities JSON from initialize request

**Side Effects:**
- Sets `MCPBASH_CLIENT_SUPPORTS_UI` (0 or 1)
- Writes state file for subprocess access

---

### mcp_client_supports_ui

Check if the connected client supports MCP Apps UI.

```bash
if mcp_client_supports_ui; then
  # Register UI-enabled tools
fi
```

**Returns:**
- `0` (success) if UI is supported
- `1` (failure) if not supported

---

### mcp_client_supports_extension

Check if client supports a specific extension.

```bash
if mcp_client_supports_extension "io.modelcontextprotocol/ui"; then
  echo "UI supported"
fi
```

**Parameters:**
- `$1` - Extension identifier (e.g., `io.modelcontextprotocol/ui`)

**Returns:**
- `0` if supported
- `1` if not supported

---

### mcp_extensions_build_server_capabilities

Build server extension capabilities for initialize response.

```bash
extensions_json="$(mcp_extensions_build_server_capabilities)"
```

**Returns:**
- JSON object with server's extension capabilities
- Empty object `{}` if client doesn't support any extensions

---

### mcp_extensions_merge_capabilities

Merge extension capabilities into base server capabilities.

```bash
full_caps="$(mcp_extensions_merge_capabilities "$base_capabilities")"
```

**Parameters:**
- `$1` - Base server capabilities JSON

**Returns:**
- Merged capabilities JSON with extensions added

---

## Resource Discovery Functions

### mcp_ui_discover

Discover all UI resources from the filesystem.

```bash
resources_json="$(mcp_ui_discover)"
```

**Scans:**
- `tools/*/ui/` - Tool-associated UI resources
- `ui/*/` - Standalone UI resources

**Returns:**
- JSON array of discovered UI resources

**Resource Object:**
```json
{
  "name": "dashboard",
  "uri": "ui://server-name/dashboard",
  "path": "/path/to/ui/dashboard",
  "entrypoint": "index.html",
  "hasHtml": true,
  "template": null,
  "description": "Dashboard UI",
  "mimeType": "text/html;profile=mcp-app",
  "csp": {...},
  "permissions": {...},
  "prefersBorder": true
}
```

---

### mcp_ui_generate_registry

Generate UI registry from discovered resources.

```bash
mcp_ui_generate_registry
```

**Side Effects:**
- Writes registry to `$MCPBASH_REGISTRY_DIR/ui-resources.json`
- Updates in-memory cache variables
- Sets `MCP_UI_TOTAL` to resource count

---

### mcp_ui_refresh_registry

Refresh registry if stale (TTL-based).

```bash
mcp_ui_refresh_registry
```

**Behavior:**
- Checks `MCP_UI_TTL` (default 5 seconds)
- Regenerates registry if expired or not loaded

---

### mcp_ui_load_registry

Load UI registry from cache file.

```bash
if mcp_ui_load_registry; then
  echo "Loaded ${MCP_UI_TOTAL} resources"
fi
```

**Returns:**
- `0` if registry loaded successfully
- `1` if registry file doesn't exist

---

### mcp_ui_registry_stale

Check if registry needs refresh.

```bash
if mcp_ui_registry_stale; then
  mcp_ui_generate_registry
fi
```

**Returns:**
- `0` if stale (needs refresh)
- `1` if fresh

---

## Resource Query Functions

### mcp_ui_get_metadata

Get UI resource metadata by name.

```bash
meta_json="$(mcp_ui_get_metadata "dashboard")"
```

**Parameters:**
- `$1` - Resource name

**Returns:**
- JSON object with `csp`, `permissions`, `prefersBorder`
- Empty object `{}` if not found

---

### mcp_ui_get_content

Get UI resource HTML content.

```bash
html="$(mcp_ui_get_content "dashboard")"
```

**Parameters:**
- `$1` - Resource name

**Returns:**
- HTML content (static or template-generated)
- Exit code `1` if not found

**Behavior:**
1. If static HTML exists, returns file contents
2. If template configured, generates HTML
3. Returns error if neither available

---

### mcp_ui_get_path_from_registry

Get filesystem path to UI resource HTML file.

```bash
path="$(mcp_ui_get_path_from_registry "dashboard")"
```

**Parameters:**
- `$1` - Resource name

**Returns:**
- Absolute path to HTML file
- Exit code `1` if not found

---

### mcp_ui_list

List all UI resources.

```bash
all_resources="$(mcp_ui_list)"
```

**Returns:**
- JSON array of all UI resources

---

### mcp_ui_count

Get count of UI resources.

```bash
count="$(mcp_ui_count)"
echo "Found ${count} UI resources"
```

**Returns:**
- Integer count

---

## CSP Functions

### mcp_ui_get_csp_header

Generate CSP header string for a UI resource.

```bash
csp="$(mcp_ui_get_csp_header "dashboard")"
# Returns: default-src 'self'; script-src 'self' https://cdn.jsdelivr.net; ...
```

**Parameters:**
- `$1` - Resource name

**Returns:**
- CSP header string ready for HTTP header
- Default restrictive policy if no metadata

**Default CSP:**
```
default-src 'self';
script-src 'self' https://cdn.jsdelivr.net;
style-src 'self' 'unsafe-inline';
img-src 'self' data:;
connect-src 'self';
frame-ancestors 'none';
base-uri 'self'
```

---

### mcp_ui_get_csp_meta

Build CSP meta JSON for resource response.

```bash
csp_json="$(mcp_ui_get_csp_meta "dashboard")"
```

**Parameters:**
- `$1` - Resource name

**Returns:**
- JSON object for `_meta.ui.csp`:
```json
{
  "connectDomains": ["api.example.com"],
  "resourceDomains": [],
  "frameDomains": [],
  "baseUriDomains": []
}
```

---

## Template Functions

### mcp_ui_generate_from_template

Generate HTML from template configuration.

```bash
html="$(mcp_ui_generate_from_template "form" "$config_json")"
```

**Parameters:**
- `$1` - Template name
- `$2` - Configuration JSON

**Returns:**
- Generated HTML
- Exit code `1` if unknown template

**Available Templates:**
- `form`
- `data-table`
- `progress`
- `diff-viewer`
- `tree-view`
- `kanban`

---

### Template-Specific Functions

Each template has its own generator function:

```bash
mcp_ui_template_form "$config"
mcp_ui_template_data_table "$config"
mcp_ui_template_progress "$config"
mcp_ui_template_diff_viewer "$config"
mcp_ui_template_tree_view "$config"
mcp_ui_template_kanban "$config"
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MCP_UI_TTL` | `5` | Registry cache TTL in seconds |
| `MCPBASH_MAX_UI_RESOURCE_BYTES` | `1048576` | Max UI resource size (1MB) |
| `MCPBASH_UI_CACHE_MAX_TEMPLATES` | `50` | Max cached template results |
| `MCPBASH_SERVER_NAME` | `mcp-server` | Server name for UI URIs |
| `MCPBASH_CLIENT_SUPPORTS_UI` | - | Set by capability detection |

---

## Global State

| Variable | Description |
|----------|-------------|
| `MCP_UI_REGISTRY_JSON` | In-memory registry cache |
| `MCP_UI_REGISTRY_HASH` | Registry content hash |
| `MCP_UI_TOTAL` | Total UI resource count |
| `MCP_UI_LAST_SCAN` | Timestamp of last scan |

---

## Example: Tool with UI

```bash
#!/usr/bin/env bash
source "${MCP_SDK}/tool-sdk.sh"

# Check if UI is available
if [ "${MCPBASH_CLIENT_SUPPORTS_UI:-0}" = "1" ]; then
  # Output with UI reference
  cat <<EOF
{
  "content": [{"type": "text", "text": "Result data"}],
  "isError": false,
  "_meta": {
    "ui": {
      "resourceUri": "ui://${MCPBASH_SERVER_NAME}/my-results"
    }
  }
}
EOF
else
  # Fallback to text-only
  mcp_result_text "Result data"
fi
```

---

## Example: Custom UI Provider

```bash
# providers/ui.sh
source "${MCPBASH_HOME}/lib/ui.sh"

mcp_provider_ui_read() {
  local uri="$1"
  local name="${uri#ui://*/}"

  local content
  content="$(mcp_ui_get_content "${name}")" || {
    mcp_result_error -32002 "UI resource not found: ${name}"
    return
  }

  local csp_meta
  csp_meta="$(mcp_ui_get_csp_meta "${name}")"

  local metadata
  metadata="$(mcp_ui_get_metadata "${name}")"

  # Build response with metadata
  # ...
}
```

---

## See Also

- [UI Resources Guide](../guides/ui-resources.md)
- [UI Templates Reference](ui-templates.md)
- [MCP Apps Concepts](../concepts/mcp-apps.md)
