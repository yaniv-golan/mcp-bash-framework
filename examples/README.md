# Examples

Run any example from the repo root:
```bash
./examples/run <example-id>
```

`examples/run` copies the selected example into a fresh temp workspace (`mktemp -d`), points `MCPBASH_PROJECT_ROOT` there, and deletes it on exit. To keep files for inspection, run an example in your own directory instead:
```bash
tmp=/tmp/mcp-example
rm -rf "$tmp"
cp -a examples/08-roots-basics/. "$tmp"
MCPBASH_HOME=$(pwd) MCPBASH_PROJECT_ROOT="$tmp" ./bin/mcp-bash
```
Browse `$tmp` after the run to see outputs and registries.

MCP Inspector (stdio) quickstart:
```bash
npx @modelcontextprotocol/inspector --transport stdio -- ./examples/run 07-elicitation
```
The `--` separator prevents the inspector from treating `./examples/run` as its own flag. Replace `07-elicitation` with any example ID (e.g., `advanced/ffmpeg-studio`).

New example:
- `09-embedded-resources` shows how a tool embeds a file in the MCP response (`type:"resource"`).
