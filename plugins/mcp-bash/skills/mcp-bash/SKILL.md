---
name: mcp-bash
description: Build, debug and package MCP servers written in Bash with the mcp-bash framework (mcp-bash-framework). Use whenever the user wants to create an MCP server from shell scripts or CLIs, add or fix tools, resources, prompts or completions in an mcp-bash project, wire one into Claude Desktop, Cursor or another client, figure out why a tool is "blocked by policy", can't see an environment variable or API key, or works in a terminal but not in Claude Desktop, or build an .mcpb bundle. Also use when a directory has server.d/server.meta.json or tools/*/tool.meta.json.
metadata:
  version: 0.1.0
---

# Building MCP servers with mcp-bash

mcp-bash turns Bash scripts into an MCP server (stdio, JSON-RPC). The framework is installed
once; each server is a separate **project** directory that the framework discovers.

This skill is the workflow and the traps. For API detail, read the reference instead of
guessing — it is short and current:

- Installed framework: `~/.local/share/mcp-bash/llms-full.txt` (default install location;
  `docs/` is next to it).
- Otherwise: https://raw.githubusercontent.com/yaniv-golan/mcp-bash-framework/main/llms-full.txt
- Topic docs, same place: `docs/BEST-PRACTICES.md`, `docs/COMPLETION.md`,
  `docs/RESOURCE-TEMPLATES.md`, `docs/MCPB.md`, `docs/ENV_REFERENCE.md`, `docs/SECURITY.md`,
  `docs/DEBUGGING.md`. Working examples: `examples/00-hello-tool` … `examples/15-cli-wrapper`.

## Workflow

1. **Check the framework.** `mcp-bash --version`. If missing, install it with the verified
   steps in the README (download `install.sh` and `SHA256SUMS`, check, run). Don't pipe an
   unverified script into bash on the user's behalf without saying so.
2. **Create the project.** `mcp-bash new <name>` (new directory) or `mcp-bash init` (current
   one). Commands run inside the project find it by walking up to `server.d/server.meta.json`.
3. **Scaffold, don't hand-write.** `mcp-bash scaffold tool|resource|prompt|completion <name>`.
   The scaffold gets the SDK sourcing, metadata shape and executable bit right. Then edit
   `tools/<name>/tool.sh` and `tool.meta.json` (`inputSchema` is the argument contract).
4. **Validate.** `mcp-bash validate` (add `--fix` for permissions). Fix every error; read the
   warnings, they usually name a real problem.
5. **Run one tool without a client.**
   `mcp-bash run-tool <name> --allow-self --args '{"key":"value"}'`.
   Without `--allow-self` the call is refused (see deny-by-default below); that refusal is
   expected, not a bug in the tool.
6. **Wire a client.** `mcp-bash config --client claude-desktop` (or `--show` for all
   clients). Keep the `MCPBASH_TOOL_ALLOWLIST` and `MCPBASH_PROJECT_ROOT` it prints.
7. **Ship.** Either `mcp-bash bundle` (an `.mcpb` for Claude Desktop; configure via
   `mcpb.conf`, see `docs/MCPB.md`) or `mcp-bash vendor` (embed the runtime in `.mcp-bash/`
   and commit it).

### Writing a tool

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

query="$(mcp_args_get '.query')"                 # required: validate it yourself
limit="$(mcp_args_int '.limit' --default 10 --min 1 --max 100)"
name="$(mcp_args_get '.name // "World"')"        # default for a string: put it in the filter

[ -n "${query}" ] && [ "${query}" != "null" ] || mcp_fail_invalid_args "query is required"

mcp_result_success "$(mcp_json_obj query "${query}" name "${name}")"
```

- **stdout is the result channel.** Anything else a command prints must go to stderr
  (`cmd >&2`), or the result is corrupt.
- Errors the model should see and react to: `mcp_error "type" "message" --hint "what to do"`.
  Bad arguments: `mcp_fail_invalid_args "msg"`.
- Long work: `mcp_progress <pct> "msg"`, and check `mcp_is_cancelled` in loops.
- Tool names: letters, digits, `_` and `-` only, up to 64 characters. **No dots** — Claude
  Desktop rejects them.
- After changing `inputSchema`, update the sample arguments in `tools/<name>/smoke.sh` if the
  scaffold created one.

## Gotchas

These fail silently or with a misleading message. Check them first when something "doesn't
work".

- **Tools are denied unless allowlisted.** The server refuses every tool not in
  `MCPBASH_TOOL_ALLOWLIST` (`*` allows all; fine for a project you trust). In a client config
  that removed it, every call fails with "blocked by policy". `run-tool` needs `--allow-self`
  (or `--allow NAME` / `--allow-all`).
- **A custom `server.d/policy.sh` must call the default first.** Defining
  `mcp_tools_policy_check` *replaces* the built-in check, allowlist included:

  ```bash
  mcp_tools_policy_check() {
  	mcp_tools_policy_check_default "$@" || return 1
  	# project rules here
  	return 0
  }
  ```

  `mcp-bash validate` and `doctor` warn when the call is missing.
- **Tools don't see your environment variables.** Tools run with a minimal environment (only
  framework `MCP_*` variables, `PATH`, `HOME`, `TMPDIR`, `LANG` and `MCPBASH_*`); resource
  providers and completion scripts get even less. An API key exported in the shell or set by
  the client config reaches the *server*, not the tool. Declare which names to pass in
  `server.d/server.meta.json`:

  ```json
  "env": {
    "MCPBASH_TOOL_ENV_MODE": "allowlist",
    "MCPBASH_TOOL_ENV_ALLOWLIST": "MY_API_KEY",
    "MCPBASH_PROVIDER_ENV_MODE": "allowlist",
    "MCPBASH_PROVIDER_ENV_ALLOWLIST": "MY_API_KEY"
  }
  ```

  Only those four keys are allowed, and they hold variable **names, never values**. A variable
  of your own named `MCP_something` also needs the allowlist. Check the result with
  `mcp-bash run-tool <name> --print-env` (names only, never values).
- **`server.d/env.sh` is not loaded by the server.** Only `run-tool --with-server-env` reads
  it. Don't put configuration there and expect a client to see it.
- **Claude Desktop runs the server with macOS `/bin/bash` 3.2** and a minimal `PATH`. Code
  that works in your terminal's bash 5 can fail there:
  - `"${arr[@]}"` on an empty array under `set -u` is an error; write `${arr[@]+"${arr[@]}"}`.
  - No associative arrays, `mapfile`, or `${var,,}`.
  - CLIs installed by pyenv, nvm, Homebrew and similar may not be on `PATH`. Resolve them
    explicitly (`mcp_detect_cli` in `docs/BEST-PRACTICES.md`, or an absolute path).
  - Test under 3.2: put a directory first on `PATH` containing only a `bash -> /bin/bash`
    symlink, then run `run-tool`.
- **Never write `"${x:-{}}"`.** Bash ends the expansion at the first `}` and appends a stray
  `}` when `x` is set. Use `local d='{}'; x="${x:-$d}"`.
- **Defaults on `mcp_args_get`:** `--default` works from mcp-bash 1.7.0; older versions
  ignore it silently, and a missing argument comes back as the string `null`. The filter form
  `'.name // "World"'` works on every version.
- **Completion scripts are found by name, next to what they complete:**
  `prompts/<name>/<name>.completion.sh` for a prompt; `resources/<template-name>.completion.sh`
  (or `resources/<name>/<name>.completion.sh`) for a resource template, which is what Claude
  Desktop asks for. The argument being completed is `.argument.name` in
  `MCP_COMPLETION_ARGS_JSON`. Details: `docs/COMPLETION.md`.
- **Resource templates:** use `{+path}` for values containing `/` (`file:///{+path}`); `{v}`
  stops at `/`. A declared `mimeType` is reported as written, so drop a wrong
  `"mimeType": "text/plain"` rather than leaving it.
- **"tool not found" right after adding a tool** usually means a cached registry. Run
  `mcp-bash registry refresh`; a running client also needs to reconnect or receive
  `list_changed`.
- **`server.d/register.sh` only runs with `MCPBASH_ALLOW_PROJECT_HOOKS=true`.** Prefer the
  data-only `server.d/register.json`.

## Debugging

- `mcp-bash doctor` — install, versions, JSON tool, effective env policy, policy.sh check.
  (Shows local paths; fine to read, think before pasting it publicly.)
- `mcp-bash validate --explain-defaults` — what the project resolves to.
- `mcp-bash run-tool <name> --allow-self --verbose --args '…'` — the tool's stderr inline.
- `mcp-bash run-tool <name> --print-env` — which variables the tool will get.
- `mcp-bash debug` as the client's command (instead of the plain binary) — logs every
  message; the log path is printed to stderr at startup. See `docs/DEBUGGING.md`.
- `mcp-bash config --inspector` — a ready command for the MCP Inspector.

When a tool works under `run-tool` but not in the client, the difference is almost always
the environment: the allowlist in the client config, `MCPBASH_PROJECT_ROOT`, the env policy,
`PATH`, or bash 3.2.
