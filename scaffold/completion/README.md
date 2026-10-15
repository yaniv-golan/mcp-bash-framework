# Completion scaffold: `__NAME__`

What you get:
- Script: `completion.sh` (manual provider) under `completions/__NAME__/`.
- Registration: added to `server.d/register.json` as a manual completion with a 5s timeout.

Usage:
- Edit `completion.sh` to emit suggestions based on the request arguments in `MCP_COMPLETION_ARGS_FILE` (see `docs/COMPLETION.md` for the contract).
- Paths are relative to `MCPBASH_PROJECT_ROOT`; tweak the registration in `server.d/register.json` if you move the script.
- Run `mcp-bash registry refresh` or restart your client to pick up changes.
