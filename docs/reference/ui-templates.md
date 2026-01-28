# UI Templates Reference

> **Note**: Templates are an **mcp-bash convenience feature**, not part of the MCP Apps specification. The spec only requires serving HTML content - templates are our solution for generating HTML from declarative JSON in pure Bash environments.

mcp-bash provides built-in templates for common UI patterns. Templates generate HTML from JSON configuration, eliminating the need to write boilerplate HTML/CSS/JS.

## Available Templates

| Template | Description |
|----------|-------------|
| `form` | Input forms with validation |
| `data-table` | Tabular data display |
| `progress` | Progress indicators |
| `diff-viewer` | Side-by-side diff comparison |
| `tree-view` | Hierarchical tree structures |
| `kanban` | Kanban board layout |

## Using Templates

In `ui.meta.json`:

```json
{
  "template": "form",
  "config": {
    "title": "My Form",
    "fields": [...]
  }
}
```

When `template` is specified and no `index.html` exists, the template generates HTML on demand.

---

## Form Template

Interactive forms that submit to server tools.

### Configuration

```json
{
  "template": "form",
  "config": {
    "title": "Contact Form",
    "description": "Please fill out the form below",
    "fields": [...],
    "submitTool": "submit-contact",
    "submitArgs": {"source": "ui"},
    "cancelable": true
  }
}
```

### Config Properties

| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `title` | string | No | `"Form"` | Form title |
| `description` | string | No | - | Description text |
| `fields` | array | Yes | - | Field definitions |
| `submitTool` | string | Yes | - | Tool to call on submit |
| `submitArgs` | object | No | `{}` | Additional args for submit |
| `cancelable` | boolean | No | `false` | Show cancel button |

### Field Definition

| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `name` | string | Yes | - | Field name (used in submission) |
| `type` | string | No | `"text"` | Input type |
| `label` | string | No | `name` | Display label |
| `required` | boolean | No | `false` | Whether field is required |
| `placeholder` | string | No | - | Placeholder text |
| `default` | string | No | - | Default value |
| `options` | array | Only for `select` | - | Select options |

### Field Types

| Type | HTML Element | Notes |
|------|--------------|-------|
| `text` | `<input type="text">` | Default |
| `email` | `<input type="email">` | Email validation |
| `password` | `<input type="password">` | Masked input |
| `number` | `<input type="number">` | Numeric input |
| `textarea` | `<textarea>` | Multi-line text |
| `select` | `<select>` | Requires `options` |
| `checkbox` | `<input type="checkbox">` | Boolean toggle |

### Example

```json
{
  "template": "form",
  "config": {
    "title": "Create User",
    "fields": [
      {"name": "username", "type": "text", "label": "Username", "required": true},
      {"name": "email", "type": "email", "label": "Email", "required": true},
      {"name": "role", "type": "select", "label": "Role", "options": ["admin", "user", "guest"], "default": "user"},
      {"name": "active", "type": "checkbox", "label": "Active", "default": "true"}
    ],
    "submitTool": "create-user",
    "cancelable": true
  }
}
```

---

## Data Table Template

Displays tabular data with optional sorting.

### Configuration

```json
{
  "template": "data-table",
  "config": {
    "title": "Results",
    "columns": [...]
  }
}
```

### Config Properties

| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `title` | string | No | `"Data"` | Table title |
| `columns` | array | Yes | - | Column definitions |

### Column Definition

| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `key` | string | Yes | - | Data property key |
| `label` | string | No | `key` | Column header |
| `sortable` | boolean | No | `false` | Enable sorting |

### Example

```json
{
  "template": "data-table",
  "config": {
    "title": "Users",
    "columns": [
      {"key": "id", "label": "ID", "sortable": true},
      {"key": "name", "label": "Name", "sortable": true},
      {"key": "email", "label": "Email"},
      {"key": "created", "label": "Created"}
    ]
  }
}
```

### Data Format

The table expects tool results in this format:

```json
[
  {"id": 1, "name": "Alice", "email": "alice@example.com", "created": "2024-01-15"},
  {"id": 2, "name": "Bob", "email": "bob@example.com", "created": "2024-01-16"}
]
```

---

## Progress Template

Shows operation progress with optional cancellation.

### Configuration

```json
{
  "template": "progress",
  "config": {
    "title": "Processing",
    "showPercentage": true,
    "showCurrentStep": true,
    "cancelTool": "cancel-operation",
    "cancelConfirm": "Are you sure?"
  }
}
```

### Config Properties

| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `title` | string | No | `"Progress"` | Progress title |
| `showPercentage` | boolean | No | `true` | Show percentage text |
| `showCurrentStep` | boolean | No | `true` | Show current step |
| `cancelTool` | string | No | - | Tool to call on cancel |
| `cancelConfirm` | string | No | `"Are you sure you want to cancel?"` | Confirmation message |

### Example

```json
{
  "template": "progress",
  "config": {
    "title": "Uploading Files",
    "showPercentage": true,
    "showCurrentStep": true,
    "cancelTool": "cancel-upload",
    "cancelConfirm": "Cancel the upload?"
  }
}
```

---

## Diff Viewer Template

Two-panel diff view with syntax highlighting.

### Configuration

```json
{
  "template": "diff-viewer",
  "config": {
    "title": "Code Changes",
    "viewMode": "split",
    "showLineNumbers": true,
    "syntaxHighlight": true,
    "leftTitle": "Original",
    "rightTitle": "Modified"
  }
}
```

### Config Properties

| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `title` | string | No | `"Diff Viewer"` | Viewer title |
| `viewMode` | string | No | `"split"` | `"split"` or `"unified"` |
| `showLineNumbers` | boolean | No | `true` | Show line numbers |
| `syntaxHighlight` | boolean | No | `true` | Enable syntax highlighting |
| `leftTitle` | string | No | `"Original"` | Left panel title |
| `rightTitle` | string | No | `"Modified"` | Right panel title |

### Data Format

```json
{
  "left": "original content\nline 2",
  "right": "modified content\nline 2\nline 3",
  "changes": [
    {"value": "modified ", "added": true, "count": 1},
    {"value": "original ", "removed": true, "count": 1}
  ]
}
```

Alternative format:
```json
{
  "original": "...",
  "modified": "..."
}
```

---

## Tree View Template

Hierarchical tree structure with expand/collapse.

### Configuration

```json
{
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

### Config Properties

| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `title` | string | No | `"Tree View"` | Tree title |
| `showIcons` | boolean | No | `true` | Show node icons |
| `expandLevel` | number | No | `1` | Initial expand depth |
| `selectable` | boolean | No | `false` | Enable selection |
| `onSelectTool` | string | No | - | Tool to call on select |

### Data Format

```json
[
  {
    "id": "src",
    "label": "src",
    "icon": "folder",
    "children": [
      {"id": "src/main.ts", "label": "main.ts", "icon": "file", "meta": "2.5 KB"},
      {"id": "src/utils.ts", "label": "utils.ts", "icon": "file"}
    ]
  },
  {
    "id": "package.json",
    "label": "package.json",
    "icon": "file"
  }
]
```

### Node Properties

| Property | Type | Description |
|----------|------|-------------|
| `id` | string | Unique identifier |
| `label` | string | Display text |
| `icon` | string | Icon type: `folder`, `folder-open`, `file`, or custom |
| `iconChar` | string | Custom icon character |
| `meta` | string | Secondary text (e.g., file size) |
| `children` | array | Child nodes |

---

## Kanban Template

Column-based kanban board with drag-drop support.

### Configuration

```json
{
  "template": "kanban",
  "config": {
    "title": "Sprint Board",
    "columns": [
      {"id": "backlog", "title": "Backlog"},
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

### Config Properties

| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `title` | string | No | `"Kanban Board"` | Board title |
| `columns` | array | No | Default 3 columns | Column definitions |
| `draggable` | boolean | No | `true` | Enable drag-drop |
| `onMoveTool` | string | No | - | Tool to call on move |
| `onCardClickTool` | string | No | - | Tool to call on click |

### Column Definition

| Property | Type | Description |
|----------|------|-------------|
| `id` | string | Column identifier |
| `title` | string | Column header |

### Card Data Format

```json
[
  {
    "id": "task-1",
    "title": "Implement feature",
    "description": "Add the new feature",
    "column": "in-progress",
    "priority": "high",
    "tags": ["frontend", "urgent"],
    "assignee": "Alice"
  },
  {
    "id": "task-2",
    "title": "Write tests",
    "column": "todo",
    "priority": "medium"
  }
]
```

### Card Properties

| Property | Type | Description |
|----------|------|-------------|
| `id` | string | Card identifier |
| `title` | string | Card title |
| `description` | string | Card description |
| `column` or `status` | string | Column ID |
| `priority` | string | `high`, `medium`, or `low` |
| `tags` | array | Tag labels |
| `assignee` | string | Assignee name |

---

## Programmatic Usage

Templates can be used directly in Bash:

```bash
source "${MCP_SDK}/tool-sdk.sh"
source "${MCPBASH_HOME}/lib/ui-templates.sh"

config='{"title":"My Form","fields":[...],"submitTool":"submit"}'
html="$(mcp_ui_generate_from_template "form" "${config}")"
```

## Extending Templates

To add custom templates, register them in `MCP_UI_TEMPLATES`:

```bash
MCP_UI_TEMPLATES[my-template]="my_template_function"

my_template_function() {
  local config="$1"
  # Generate and output HTML
}
```

## See Also

- [UI Resources Guide](../guides/ui-resources.md)
- [MCP Apps Concepts](../concepts/mcp-apps.md)
- [UI SDK Reference](ui-sdk.md)
