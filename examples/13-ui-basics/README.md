# 13-ui-basics

**What you'll learn**
- How to create UI resources for MCP Apps
- Tool-associated UI (tools/*/ui/)
- Standalone UI resources (ui/*/)
- UI metadata configuration (ui.meta.json)
- MCP Apps capability negotiation

**Prereqs**
- Bash 3.2+
- jq or gojq
- MCP client with UI support (Claude Desktop, etc.)

**Structure**
```
13-ui-basics/
├── server.d/
│   └── server.meta.json
├── tools/
│   └── weather/
│       ├── tool.sh
│       ├── tool.meta.json
│       └── ui/
│           ├── index.html
│           └── ui.meta.json
└── ui/
    └── standalone-dashboard/
        ├── index.html
        └── ui.meta.json
```

**Run**
```bash
./examples/run 13-ui-basics
```

**Key Concepts**

1. **Tool-associated UI**: The weather tool has a UI in `tools/weather/ui/`. When the tool is called, the result includes `_meta.ui.resourceUri` pointing to this UI.

2. **Standalone UI**: The dashboard in `ui/standalone-dashboard/` is independent and can be referenced by any tool or accessed directly.

3. **UI Metadata**: Each UI has `ui.meta.json` with:
   - `description`: Human-readable description
   - `meta.csp`: Content Security Policy domains
   - `meta.prefersBorder`: Whether to show border

**Transcript**
```
> initialize (with UI capability)
< {"result":{"capabilities":{"extensions":{"io.modelcontextprotocol/ui":{...}}}}}

> tools/call weather
< {"result":{"content":[...],"_meta":{"ui":{"resourceUri":"ui://ui-basics-example/weather"}}}}

> resources/read uri=ui://ui-basics-example/weather
< {"result":{"contents":[{"mimeType":"text/html;profile=mcp-app","text":"<!DOCTYPE html>..."}]}}
```

**Success criteria**
- Server advertises UI extension capability
- Tool result includes `_meta.ui.resourceUri`
- `resources/read` returns HTML with `text/html;profile=mcp-app` MIME type
- UI renders correctly in supporting clients

**Troubleshooting**
- If UI doesn't appear, verify client supports `io.modelcontextprotocol/ui` extension
- Check `ui.meta.json` is valid JSON
- Ensure `index.html` exists or template is configured
