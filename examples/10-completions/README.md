# 10-completions

**What you'll learn**
- How to register a completion with `server.d/register.json`
- How completion scripts read `.query` (or `.prefix`) and paginate results
- How `hasMore`/`nextCursor` behave when the server derives cursors for you

**Prereqs**
- Bash 3.2+
- jq or gojq (completion requires JSON tooling)

**Run**
```
./examples/run 10-completions
```

**What it does**
1. Registers `demo.completion` via a manual provider.
2. Completion script filters a small catalog by the typed query/prefix.
3. Returns 3 suggestions at a time with `hasMore` and framework-generated cursors until results are exhausted.
4. Exposes a `demo.completion` prompt argument in `prompts/` so the Inspector UI can trigger completions from the Prompts tab.

**Script contract (manual)**
- Env: `MCP_COMPLETION_NAME`, `MCP_COMPLETION_ARGS_JSON`, `MCP_COMPLETION_LIMIT`, `MCP_COMPLETION_OFFSET`, `MCP_COMPLETION_ARGS_HASH`, `MCPBASH_JSON_TOOL_BIN`.
- Stdout: `string[]` (or an object with `suggestions: string[]`, `hasMore`, optional `next`/`cursor`).

**Success criteria**
- `completion/complete` with `{"ref":{"type":"ref/prompt","name":"demo.completion"},"argument":{"name":"query","value":"re"}}` returns matches like `retry`, `review`, etc.
- Responses include `hasMore=true` on the first page and an opaque `nextCursor`; subsequent calls with `cursor` walk the remaining results.
- In the Inspector UI: go to **Prompts** → **List Prompts** → select `demo.completion` → focus/type in `query` to see completion suggestions.

See also: [docs/COMPLETION.md](../../docs/COMPLETION.md) for the full guide.
