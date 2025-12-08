# Embedded Resource Discoverability Plan

## Goals
- Make `type:"resource"` embedding easy to find and use for tool authors.
- Ensure agent/LLM guidance mentions the feature and the env/file contract.
- Provide a working example so users can copy/paste and test.

## Steps (finalized)
1) **Docs: surface how-to**
	- README: add a short “Embedded resources” subsection under the Tools/output area with what it does, how to write `MCP_TOOL_RESOURCES_FILE` (TSV or JSON array), and a minimal snippet. Mention binary auto-base64 to `blob`.
	- BEST-PRACTICES: add a fuller subsection under tools/output guidance with formats, snippet, and a binary note. Link to the example.
	- ARCHITECTURE: keep the existing one-liner (no expansion).
	- REGISTRY: no change (not about runtime payloads).
	- Clarify binary behavior: binary files are base64-encoded into the `blob` field; text stays in `text`.
2) **Example (new)**
	- Add `examples/09-embedded-resources/`:
		- Tool writes a small file, appends to `MCP_TOOL_RESOURCES_FILE`, returns a text fallback.
		- README shows `mcp-bash run-tool` usage.
	- Reuse existing example style (minimal code + README).
3) **Scaffolding hint**
	- In the scaffolded `tool.sh` (or its README), add a commented line showing `printf '%s\ttext/plain\n' "$path" >> "$MCP_TOOL_RESOURCES_FILE"` (and mention JSON array as an alternative). Keep it brief to avoid clutter.
4) **LLM guides**
	- Update `llms.txt` and `llms-full.txt` to mention the env var, accepted formats (TSV/JSON), binary auto-encoding to `blob`, and when to use it (attach files/logs directly). Include a JSON example, e.g. `[{"path":"/tmp/result.png","mimeType":"image/png"}]`.
5) **Diagnostics (required)**
	- Add debug-level logs when:
		- An embed is skipped (outside roots, unreadable, or invalid format).
		- A tool writes to `MCP_TOOL_RESOURCES_FILE` but no embeds are added.
	- Keep logging at debug to avoid noise while surfacing failures.

## Acceptance
- README + BEST-PRACTICES document the feature with a runnable snippet; ARCHITECTURE remains minimal; REGISTRY untouched.
- Example tool demonstrates the feature and passes existing smoke/integration.
- Scaffold hints include a commented embed example.
- LLM guides mention env var, formats, and binary handling.
- Debug logs fire on skipped embeds/empty additions.
- No shfmt/shellcheck regressions; integration tests still pass.
