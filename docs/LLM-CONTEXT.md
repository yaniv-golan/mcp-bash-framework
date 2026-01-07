# LLM Context Patterns

This guide covers patterns for building MCP servers that LLM agents can use effectively. When an LLM interacts with your tools, it only sees the metadata you provide - making rich, actionable descriptions essential for successful tool use.

## Table of Contents

- [The Context Problem](#the-context-problem)
- [Writing Effective Tool Descriptions](#writing-effective-tool-descriptions)
- [Parameter Descriptions](#parameter-descriptions)
- [Including Examples](#including-examples)
- [Documenting Tool Relationships](#documenting-tool-relationships)
- [Domain Model Resources](#domain-model-resources)
- [Discovery Tool Patterns](#discovery-tool-patterns)
- [Anti-Patterns](#anti-patterns)
- [Checklist](#checklist)

## The Context Problem

LLMs using MCP tools face several challenges:

| Challenge | Impact |
|-----------|--------|
| No domain knowledge | LLM doesn't understand your data model or business concepts |
| Limited tool visibility | Only sees tool name, description, and input schema |
| No workflow context | Doesn't know which tools work together or in what order |
| Syntax ambiguity | Guesses at filter syntax, date formats, or special values |

**Your metadata is the only context the LLM has.** Every piece of information you omit is something the LLM must guess.

## Writing Effective Tool Descriptions

The `description` field in `tool.meta.json` is your primary communication channel with the LLM. Use it fully.

### Bad: Minimal Description

```json
{
  "name": "list-export",
  "description": "Export list entries"
}
```

The LLM doesn't know:
- What a "list" is in your domain
- What format the export produces
- When to use this vs other tools
- What parameters are important

### Good: Rich Description

```json
{
  "name": "list-export",
  "description": "Export entries from a specific list to JSON. Lists are collections of entities (companies, people) with custom fields. Use this tool when you need to filter or retrieve entities that belong to a particular list. NOT for searching all entities globally - use 'company-search' or 'person-search' for that.\n\nExamples:\n- list-export --list-id 123\n- list-export --list-id 456 --filter 'Status=Active'\n- list-export --list-id 789 --limit 50\n\nFilter syntax: field=value, field!=value, field~=contains"
}
```

### Description Template

Structure your descriptions with these sections:

```
[One-line summary of what the tool does]

[When to use this tool - and when NOT to use it]

[Key concepts the LLM needs to understand]

Examples:
- [Common use case 1]
- [Common use case 2]
- [Edge case or advanced usage]

[Syntax notes for special parameters like filters]
```

## Parameter Descriptions

Every parameter in `inputSchema.properties` should have a clear `description`:

### Bad: Type-Only Schema

```json
{
  "inputSchema": {
    "type": "object",
    "properties": {
      "filter": { "type": "string" },
      "limit": { "type": "integer" }
    }
  }
}
```

### Good: Documented Parameters

```json
{
  "inputSchema": {
    "type": "object",
    "properties": {
      "filter": {
        "type": "string",
        "description": "Filter expression using field=value syntax. Operators: = (equals), != (not equals), ~= (contains), ^= (starts with), $= (ends with). Example: 'Status=Active' or 'Name~=Acme'"
      },
      "limit": {
        "type": "integer",
        "description": "Maximum entries to return (1-1000, default 100). Use smaller limits for exploratory queries.",
        "minimum": 1,
        "maximum": 1000,
        "default": 100
      }
    }
  }
}
```

### Enum Values

When parameters have specific allowed values, use `enum` with descriptions:

```json
{
  "format": {
    "type": "string",
    "enum": ["json", "csv", "table"],
    "description": "Output format. 'json' for programmatic use, 'csv' for spreadsheets, 'table' for human reading"
  }
}
```

## Including Examples

Examples are the most effective way to teach an LLM correct usage. Include them in the tool description:

```json
{
  "description": "Search companies by name or domain.\n\nExamples:\n- company-search --query 'Acme Corp'\n- company-search --domain 'acme.com'\n- company-search --query 'tech' --limit 20\n- company-search --filter 'industry=Software'"
}
```

### Example Selection

Include examples that cover:

1. **Basic usage** - The simplest successful call
2. **Common parameters** - The most-used optional parameters
3. **Edge cases** - Special syntax or less obvious features
4. **What NOT to do** - If there's a common mistake, show the correct way

## Documenting Tool Relationships

When tools work together in workflows, document the relationships:

### In Tool Descriptions

```json
{
  "name": "list-get",
  "description": "Get details about a specific list including its custom fields.\n\nTypical workflow:\n1. Use 'list-search' to find list by name\n2. Use 'list-get' to see available fields (this tool)\n3. Use 'list-export' to retrieve entries with filters\n\nRelated tools: list-search, list-export, field-list"
}
```

### Workflow Hints in Output

Tools can include workflow hints in their responses:

```json
{
  "success": true,
  "result": {
    "list": { "id": 123, "name": "Dealflow" },
    "fields": ["Status", "Owner", "Value"]
  },
  "_hints": {
    "nextSteps": [
      "Use 'list-export --list-id 123' to get entries",
      "Filter by fields: --filter 'Status=Active'"
    ]
  }
}
```

## Domain Model Resources

For complex domains, create an MCP resource that explains your data model. This gives LLMs a reference they can read before using tools.

### File Structure

```
my-mcp-server/
├── resources/
│   └── domain-model/
│       ├── domain-model.meta.json   # Resource metadata
│       └── domain-model.md          # The actual content
├── tools/
│   └── ...
└── server.d/
    └── server.meta.json
```

The built-in `file` provider automatically serves resources from the `resources/` directory. LLMs can read your domain model via `resources/read` with the resource URI.

### Creating a Domain Model Resource

**File:** `resources/domain-model/domain-model.meta.json`
```json
{
  "name": "domain-model",
  "description": "Conceptual guide to the data model - read this first to understand how entities, lists, and fields relate",
  "uri": "help://domain-model",
  "mimeType": "text/markdown"
}
```

**File:** `resources/domain-model/domain-model.md`
```markdown
# Data Model Overview

## Core Concepts

### Entities
Entities (Companies, People, Opportunities) exist globally in the CRM.
- Access via: `company-search`, `person-search`, `opportunity-search`
- Filters: Core fields only (name, domain, email)

### Lists
Lists are collections that can contain entities.
- Each list has custom Fields (columns defined by users)
- Access via: `list-search`, `list-get`

### List Entries
When an entity is added to a list, it becomes a List Entry.
- Entries have Field Values for that list's custom fields
- Access via: `list-export`, `entry-get`
- Filters: Based on field values

## Common Workflows

### Find entities on a specific list with a field value
1. `list-search --name "Dealflow"` → get list_id
2. `list-export --list-id <id> --filter "Status=New"`

### Search all companies globally
1. `company-search --query "Acme"` (NOT list-export)

## Filter Syntax
All commands use: `--filter 'field operator "value"'`
- Operators: `=`, `!=`, `~=` (contains), `^=` (starts), `$=` (ends)
```

### Dynamic Domain Resources

Use a project-level provider for dynamic documentation:

**File:** `providers/help.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

uri="${1:-}"
case "${uri}" in
  help://commands)
    # Generate command reference dynamically
    my-cli help --format markdown
    ;;
  help://fields/*)
    list_id="${uri#help://fields/}"
    # Show available fields for a specific list
    my-cli field list --list-id "$list_id" --format markdown
    ;;
  *)
    echo "Unknown help topic: ${uri}" >&2
    exit 3
    ;;
esac
```

### Client Compatibility Note

Some MCP clients (including Claude Desktop as of early 2026) do not fully support custom URI schemes in `resources/read`. If your domain model resource uses a custom scheme like `myapp://data-model` and client compatibility is important, you have two options:

**Option 1: Use `file://` URIs (simpler)**

Stick with standard `file://` URIs which have broad client support. Place your domain model as a static markdown file and reference it with a file URI:

```json
{
  "uri": "file:///path/to/resources/domain-model/domain-model.md",
  "mimeType": "text/markdown"
}
```

**Option 2: Create a dedicated tool (for dynamic content)**

If you need dynamic content or prefer custom URI schemes, create a dedicated tool as a workaround:

```json
{
  "name": "read-myapp-resource",
  "description": "Read myapp:// resources. Use this to access domain documentation and dynamic content.\n\nExamples:\n- read-myapp-resource --uri 'myapp://data-model'\n- read-myapp-resource --uri 'myapp://fields/123'",
  "inputSchema": {
    "type": "object",
    "properties": {
      "uri": {
        "type": "string",
        "description": "The myapp:// URI to read. Available: myapp://data-model, myapp://fields/<list-id>"
      }
    },
    "required": ["uri"]
  }
}
```

The tool implementation delegates to your provider:

```bash
#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"

uri="$(mcp_args_require '.uri')"

# Delegate to provider
content=$("${MCPBASH_PROJECT_ROOT}/providers/myapp.sh" "${uri}") || {
  mcp_result_error "$(mcp_json_obj error "Failed to read resource" uri "${uri}")"
  exit 0
}

mcp_result_success "$(mcp_json_obj content "${content}" uri "${uri}")"
```

This pattern ensures LLMs can access your domain documentation regardless of client `resources/read` support.

## Discovery Tool Patterns

For servers with many tools, provide a discovery mechanism:

### Command Discovery Tool

```json
{
  "name": "discover-commands",
  "description": "Search available commands by keyword or category. Use this when unsure which tool to use for a task.\n\nExamples:\n- discover-commands --query 'export'\n- discover-commands --category 'lists'\n- discover-commands --query 'filter entries'"
}
```

### Enhancing Discovery Results

Include actionable context in discovery output:

```json
{
  "matches": [
    {
      "name": "list-export",
      "description": "Export entries from a list",
      "whenToUse": "To get entities that belong to a specific list",
      "notFor": "Searching all entities globally",
      "relatedCommands": ["list-search", "list-get"]
    }
  ],
  "suggestion": "To filter list entries, first use 'list-get' to see available fields"
}
```

## Anti-Patterns

### 1. Duplicate Information Across Tools

**Bad:** Each tool repeats filter syntax documentation
**Good:** Reference a shared resource: "See help://filter-syntax for filter operators"

### 2. Technical Descriptions Without Context

**Bad:** "Executes GET /api/v2/lists/{id}/entries"
**Good:** "Retrieves all entries from a list. Entries are entities (companies/people) that have been added to this list."

### 3. Missing Negative Guidance

**Bad:** Only describing what a tool does
**Good:** Also describing what it's NOT for and common mistakes

### 4. Assuming Domain Knowledge

**Bad:** "Export list entries with field filters"
**Good:** "Export entries from a list. Lists are collections with custom fields. Use --filter with field names from the list's schema."

### 5. Generic Parameter Names Without Context

**Bad:** `"id": { "type": "string" }`
**Good:** `"listId": { "type": "string", "description": "List ID from list-search results" }`

## Checklist

Use this checklist when documenting MCP tools for LLM consumption:

### Tool Description
- [ ] One-line summary explains the core function
- [ ] "When to use" guidance included
- [ ] "When NOT to use" or common mistakes noted
- [ ] At least 2-3 usage examples provided
- [ ] Related tools mentioned
- [ ] Special syntax (filters, dates) documented

### Parameters
- [ ] Every parameter has a description
- [ ] Enum values explained, not just listed
- [ ] Default values documented
- [ ] Valid ranges specified for numbers
- [ ] Format requirements stated for strings (dates, IDs, etc.)

### Domain Context
- [ ] Domain model resource exists for complex domains
- [ ] Key concepts explained in tool descriptions
- [ ] Workflow sequences documented
- [ ] Discovery tool available for large tool sets

### Output
- [ ] Output schema documented
- [ ] Workflow hints included where helpful
- [ ] Error messages are actionable ("try X instead")

## Further Reading

- [BEST-PRACTICES.md](BEST-PRACTICES.md) - SDK patterns and tool development
- [REGISTRY.md](REGISTRY.md) - How metadata flows to registries
- [ERRORS.md](ERRORS.md) - Error handling patterns for LLM self-correction
