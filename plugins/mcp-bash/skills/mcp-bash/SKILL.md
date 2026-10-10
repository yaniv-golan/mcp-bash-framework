---
name: mcp-bash
description: Build, debug and package MCP servers written in Bash with the mcp-bash framework (mcp-bash-framework). Use whenever the user wants to create an MCP server from shell scripts or CLIs, add or fix tools, resources, prompts or completions in an mcp-bash project, wire one into Claude Desktop, Cursor or another client, figure out why a tool is "blocked by policy", can't see an environment variable or API key, or works in a terminal but not in Claude Desktop, when tool errors show only an exit code, when completions or suggestions don't appear in Claude Desktop, when wrapping an existing CLI (Python, Node, Go) as MCP tools, or to build an .mcpb bundle. Also use when a repo has server.d/server.meta.json, tools/*/tool.meta.json, mcp-bash.lock, a vendored .mcp-bash/ directory or mcpb.conf.
metadata:
  version: 0.2.0
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

1. **Check the framework.** `mcp-bash --version`. If missing, use the README's verified
   install (checksum-checked `install.sh`) or `brew install yaniv-golan/mcp-bash/mcp-bash`.
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
- **Result helpers don't end the tool.** `mcp_result_success`, `mcp_result_error` and
  `mcp_error` print a result and return; in an early-return branch follow them with `exit 0`,
  or the tool keeps going and prints a second result (or does the work it just refused).
  `mcp_fail` and `mcp_fail_invalid_args` do exit.
- Long work: `mcp_progress <pct> "msg"`, and check `mcp_is_cancelled` in loops.
- Tool names: letters, digits, `_` and `-` only, up to 64 characters. **No dots** — Claude
  Desktop rejects them.
- **Wrapping a CLI:** pass its error through once. `mcp_with_retry` retries every exit code
  above 2, so a CLI whose codes 3+ are permanent (auth, not found) runs three times and
  prints three JSON error documents into one stdout. That is invalid JSON, and the model sees
  only "exited with code 3". Don't retry permanent errors; use `set -uo pipefail` (no `-e`)
  and return the CLI's message with `mcp_error`. Pattern: `examples/15-cli-wrapper`.
- **Never paste values into a jq program.** Use `--arg`/`--argjson`; an argument spliced
  into the filter is jq injection, and anything the tool can read (API keys) can leak.
- **Confirming destructive actions with elicitation:** handle accept, decline, cancel and no
  answer as four separate outcomes, and raise the tool's `timeoutSecs` (for example 120) so a
  person has time to answer. The `mcp_elicit*` helpers return non-zero when no answer came
  back (client without elicitation, timeout, cancelled call), so under `set -e` write
  `resp="$(mcp_elicit_confirm "Delete it?")" || true` and branch on `.action`; otherwise the
  tool dies at the prompt. See "Using the helpers under `set -e`" in `docs/ELICITATION.md`.
  **Claude Desktop extensions (`.mcpb`) get no elicitation at all** (checked in 2.31226.1), so
  the no-answer fallback (for example "call again with `confirm: true`") is the real safety
  gate there; design it as the main path.
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

  - Only those four keys are allowed, and they hold variable **names, never values**.
  - `MCPBASH_*` and framework `MCP_*` names are reserved: listing one makes the whole list
    invalid (ignored with a warning, and `mcp-bash bundle` fails). Your own `MCP_something`
    variables are fine and do need listing.
  - A mode or allowlist set in the **launch environment** (client config, a wrapper script)
    replaces the `server.meta.json` value for that scope; the two are not merged. If a
    launcher sets one, keep the two lists identical.
  - Use `"env"` in `server.meta.json` rather than Claude Desktop `platform_overrides.<os>.env`,
    which replaces the base `env` instead of adding to it.
  - Check with `mcp-bash run-tool <name> --print-env` (names only, never values).
- **`server.d/env.sh` is not loaded by the server.** Only `run-tool --with-server-env` reads
  it (and launchers you write yourself). Don't put configuration there and expect a client to
  see it.
- **MCPB `user_config` booleans arrive as strings** (`"true"`/`"false"`), so `[ "$X" = 1 ]`
  never fires. Accept `1`, `true` and `TRUE`.
  (`MCPBASH_LOG_LEVEL` itself accepts `true`/`false`.) Claude Desktop 2.31226.1 has also been
  seen saving a boolean toggle as `false` after the user switched it on, so check what arrived.
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
- **Completions:**
  - Scripts are found by name next to what they complete:
    `prompts/<name>/<name>.completion.sh`, or `resources/<template-name>.completion.sh` (or
    `resources/<name>/<name>.completion.sh`) for a resource template. The argument being
    completed is `.argument.name` in `MCP_COMPLETION_ARGS_JSON`. See `docs/COMPLETION.md`.
  - **Claude Desktop sends no completion requests** to installed extensions (checked in
    2.31226.1), and its menu has no picker for templated resources. Completions help other
    clients (MCP Inspector, Cursor and others); for Desktop users, list valid values in the
    argument's `description`.
  - A script is killed after 5 s (`MCPBASH_COMPLETION_TIMEOUT_SECS`), and a non-zero exit
    becomes a JSON-RPC error instead of an empty list. Fail soft: trap errors, print
    `{"suggestions":[],"hasMore":false}` and exit 0; give inner CLI calls a short timeout and
    no retries.
- **Executable bits must be in git** (mode `100755`), not just on disk: `validate --fix`
  repairs your checkout, not a fresh clone. Check with `git ls-files -s`.
- **Resource templates:**
  - Use `{+path}` for values containing `/` (`file:///{+path}`); `{v}` stops at `/`.
  - The provider gets the concrete URI as `$1`, percent-encoded. Decode `%HH` once with a
    decoder of your own (not `printf %b`, which mangles `100% Club` and `\c`). Then reject
    empty values, values starting with `-`, control characters and `..`; a strict pattern
    such as `^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$` is safest for paths.
  - A declared `mimeType` is reported as written, so drop a wrong `"mimeType": "text/plain"`
    rather than leaving it.
- **"tool not found" right after adding a tool:** before mcp-bash 1.7.0, `run-tool` reused a
  cached registry; run `mcp-bash registry refresh`. A running client sees new tools after it
  reconnects or gets `list_changed`.
- **`server.d/register.sh` only runs with `MCPBASH_ALLOW_PROJECT_HOOKS=true`.** Prefer the
  data-only `server.d/register.json`. Both are refused if group- or world-writable
  (`chmod g-w,o-w`).
- **Bundles ship a pre-built registry.** `mcp-bash bundle` regenerates `.registry/`; if it
  warns that pre-generation failed, fix that before shipping, or Claude Desktop serves stale
  tools, prompts and resources.
- **Smaller traps:** a helper function named `jq` recurses (call `command jq` inside it);
  `local LC_ALL=C` inside a command substitution has been flaky under bash 5.3 (set it on the
  command instead).

## Debugging

- `mcp-bash doctor` — install, versions, JSON tool, effective env policy, policy.sh check.
- `mcp-bash validate --explain-defaults` — what the project resolves to.
- `mcp-bash run-tool <name> --allow-self --verbose --args '…'` — the tool's stderr inline.
- `mcp-bash run-tool <name> --print-env` — which variables the tool will get.
- `mcp-bash debug` as the client's command (instead of the plain binary) — logs every
  message; the log path is printed to stderr at startup. See `docs/DEBUGGING.md`.

When a tool works under `run-tool` but not in the client, the difference is almost always
the environment: the allowlist in the client config, `MCPBASH_PROJECT_ROOT`, the env policy,
`PATH`, or bash 3.2.
