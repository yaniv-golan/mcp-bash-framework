# Example 15: CLI Wrapper

Demonstrates wrapping external CLI tools in MCP with proper PATH resolution and error handling — the most common real-world pattern for mcp-bash servers.

## Key Patterns

1. **Always source the SDK** — `source "${MCP_SDK:?}/tool-sdk.sh"` gives you `mcp_args_get`, `mcp_result_success`, `mcp_result_error`, `mcp_json_obj`, etc. Never parse JSON with raw jq in tool scripts.

2. **Use `mcp_detect_cli` for PATH resolution** — MCP hosts (Claude Desktop, Cursor) launch servers with a minimal PATH. CLIs installed via version managers (pyenv, nvm, etc.) won't be found. Copy `lib/cli-detect.sh` into your project and use `mcp_detect_cli` to find them.

3. **Use `set -uo pipefail` (no `-e`) for CLI wrappers** — The scaffold default `set -euo pipefail` exits on any non-zero return. External CLIs often return non-zero for business errors (e.g., "not found"). Without `-e`, you can capture the error and convert it to an MCP error response.

4. **Use `mcp_result_success` / `mcp_result_error`** — These helpers produce correctly-formatted MCP `CallToolResult` envelopes. Raw CLI output piped to stdout won't be a valid MCP response.

## Structure

```
15-cli-wrapper/
├── server.d/
│   └── server.meta.json    # Server identity
├── lib/
│   └── cli-detect.sh       # Reusable CLI detection helper
├── tools/
│   └── system-info/
│       ├── tool.meta.json   # Tool metadata + input schema
│       ├── tool.sh          # Implementation (SDK + detect + error handling)
│       └── smoke.sh         # Quick validation script
├── README.md
└── Makefile
```

## Try it

```bash
# From this directory:
mcp-bash run-tool system-info --allow-self --args '{"command":"os"}'
mcp-bash run-tool system-info --allow-self --args '{"command":"uptime"}'
mcp-bash run-tool system-info --allow-self --args '{"command":"disk"}'
```
