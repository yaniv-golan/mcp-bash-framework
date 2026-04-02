# Examples

Run any example from the repo root:
```bash
./examples/run <example-id>
```

`examples/run` copies the selected example into a fresh temp workspace (`mktemp -d`), points `MCPBASH_PROJECT_ROOT` there, and deletes it on exit. To keep files for inspection, run an example in your own directory instead:
```bash
tmp=/tmp/mcp-example
rm -rf "$tmp"
cp -a examples/04-roots-basics/. "$tmp"
MCPBASH_HOME=$(pwd) MCPBASH_PROJECT_ROOT="$tmp" ./bin/mcp-bash
```
Browse `$tmp` after the run to see outputs and registries.

MCP Inspector (stdio) quickstart:
```bash
npx @modelcontextprotocol/inspector --transport stdio -- ./examples/run 08-elicitation
```
The `--` separator prevents the inspector from treating `./examples/run` as its own flag. Replace `08-elicitation` with any example ID (e.g., `advanced/ffmpeg-studio`).

Highlights:
- `10-completions` — manual completion registration, query filtering, pagination/hasMore.
- `08-elicitation` — confirm/choice/multi-choice flows when clients advertise elicitation.
- `11-resource-templates` — auto/manual template discovery, overrides, and client-side expansion.
- `advanced/register-sh-hooks` — advanced project hooks via `server.d/register.sh` (dynamic registration; opt-in).
- [15-cli-wrapper](./15-cli-wrapper/) — Wrapping external CLI tools with PATH resolution (`mcp_detect_cli`), error handling (`set -uo pipefail`), and proper MCP result formatting. Start here if your MCP server calls an external CLI.
- Full ladder lives in the main README table.
