# 16 — Interactive UI Templates (callServerTool round-trip)

This example demonstrates an **interactive** MCP Apps template: a UI that calls
back into a server tool from inside the iframe via `app.callServerTool(...)`.

It exists to test the fix where the generated templates previously called a
non-existent `app.callTool(...)` method (which threw at runtime). The templates
now use the correct SDK API: `app.callServerTool({ name, arguments })` and
`app.sendMessage({ role, content })`.

## What's here

| Tool | Purpose |
|------|---------|
| `new-contact` | Has a `ui/` generated from the **`form`** template (no `index.html`). Rendering it shows a contact form. |
| `save-contact` | The form's `submitTool`. When you press **Submit**, the form calls `app.callServerTool({ name: "save-contact", arguments: {…} })`; the host proxies it to this tool, which returns a confirmation the UI displays. |

Flow: **agent calls `new-contact` → host renders the form → you fill it and press Submit → form calls `save-contact` → result shown in the UI.**

## A) Verify locally (no host needed — the protocol/wiring)

This is everything except the actual iframe render; it confirms the server
serves the correct HTML and the tool round-trip works.

```bash
cd /path/to/mcp-bash

# 1. Structure is valid
bin/mcp-bash validate --project-root examples/16-ui-interactive

# 2. The form HTML uses the correct SDK call (and no app.callTool)
printf '%s\n' \
  '{"jsonrpc":"2.0","id":"i","method":"initialize","params":{"capabilities":{"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":"rd","method":"resources/read","params":{"uri":"ui://ui-interactive-example/new-contact"}}' \
  | MCPBASH_PROJECT_ROOT="$PWD/examples/16-ui-interactive" MCPBASH_SERVER_NAME="ui-interactive-example" bin/mcp-bash \
  | grep -o "app.callServerTool({ name: '[^']*'"
# expect: app.callServerTool({ name: 'save-contact'

# 3. The submit target works (this is exactly what the host does on Submit)
printf '%s\n' \
  '{"jsonrpc":"2.0","id":"i","method":"initialize","params":{"capabilities":{}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":"c","method":"tools/call","params":{"name":"save-contact","arguments":{"name":"Ada","email":"ada@example.com"}}}' \
  | MCPBASH_PROJECT_ROOT="$PWD/examples/16-ui-interactive" MCPBASH_TOOL_ALLOWLIST='*' bin/mcp-bash \
  | grep '"c"'
# expect: a result with "saved":"true", name "Ada", and the "round-trip worked" note
```

## B) Test in Claude (Desktop) — the real iframe round-trip

1. Get the config snippet:
   ```bash
   bin/mcp-bash config --project-root examples/16-ui-interactive --show
   ```
2. Copy the **Claude Desktop** block into
   `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) /
   `%APPDATA%\Claude\claude_desktop_config.json` (Windows), merging into any
   existing `mcpServers`. **Fully quit and reopen** Claude Desktop.
3. In a chat, ask: **"Open a new contact form"** (this invokes the `new-contact`
   tool). The form should render inline.
4. Fill **Name** + **Email**, press **Submit**.
5. ✅ **Success:** the form shows "Form submitted successfully", and the
   `save-contact` tool runs (you'll see its result / a tool-call entry). The
   browser devtools console for the iframe should show **no** `app.callTool is
   not a function` error.
6. ❌ **If it fails:** open the app's developer console; a `TypeError:
   app.callTool is not a function` would mean an old build — confirm you're
   running this branch.

## C) Test in ChatGPT (Apps SDK)

ChatGPT supports MCP Apps natively. Use a developer/Apps-SDK MCP connector
pointing at this server (ChatGPT needs the server reachable per OpenAI's
[Apps SDK docs](https://developers.openai.com/apps-sdk/build/mcp-server) — a
local stdio server typically needs a bridge/tunnel). Then invoke `new-contact`,
submit the form, and confirm `save-contact` runs.

## Notes

- The other interactive templates (`progress` cancel, `tree-view` select,
  `kanban` move/click) use the **same** `app.callServerTool(...)` mechanism — if
  this form round-trip works, they work too.
- `data-table` and `diff-viewer` are receive-only (no tool calls).
- The generated form HTML is also checked in CI: `test/unit/ui_templates.bats`
  asserts interactive templates emit `app.callServerTool({` and never
  `app.callTool(`.
