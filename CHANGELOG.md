# Changelog

All notable changes to mcp-bash-framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Changes for 2.0.0.

### Behaviour changes to check before upgrading
- **Every tool failure is an error result, never a JSON-RPC error**: once a tool has run, the client always gets a result with `isError: true`, `_meta.exitCode` and `_meta.stderr`, so the model can read why the call failed. The error results below also have `_meta["mcpbash/error"]` (with `type`). Before, these were JSON-RPC errors the model never saw:
  - a non-zero exit (`-32603 "Tool failed"`): now type `tool_failed`, with the stderr tail as the text (or the end of stdout when stderr is empty);
  - a `{"code": N, "message": "..."}` object printed on stdout before a non-zero exit, whose code was sent as the JSON-RPC error code: now its message is the text, and the code is not sent;
  - output or stderr over `MCPBASH_MAX_TOOL_OUTPUT_SIZE`/`MCPBASH_MAX_TOOL_STDERR_SIZE`: now type `output_too_large`;
  - output that isn't valid JSON, is empty or doesn't match the tool's `outputSchema`: now type `output_schema`. Only a failure to run the check itself stays a `-32603` error.

  Clients or tests that expected `error.code` from a failed `tools/call` must check `result.isError` instead. The 1.x error's `error.data.exitCode`, `error.data.stderrTail` and `error.data.traceLine` are now `result._meta.exitCode`, `result._meta.stderr` and `result._meta["mcpbash/error"].data.traceLine`. The model now reads the tool's stderr tail: set `MCPBASH_TOOL_STDERR_CAPTURE=false` for tools that may print secrets to stderr.
- **`mcp_fail CODE MESSAGE` no longer sends a JSON-RPC error**: the numeric form is removed in 2.0. It still ends the tool, with `MESSAGE` as an error result (type `invalid_args` for `-32602`, `tool_failed` otherwise), and the tool's stderr says the form was removed; the code is not sent. `mcp_fail_invalid_args` gives an `invalid_args` error result. Run `mcp-bash migrate` to rewrite both; it rewrites `mcp_fail -32603` to `--type tool_failed` (it was `--type internal`), and no longer reports a one-argument `mcp_fail "message"`, which is valid in 2.0. <!-- lint-api-usage: allow -->
- **`mcp-bash run-tool` exits 1 for every error result**: including `mcp_fail --type`, a timeout and a failed exit, as well as a policy denial (which already did). Before, error results exited 0. Scripts that ran a tool with `run-tool` and ignored its result now see the failure.
- **`_meta.exitCode` is the tool's real exit status** for results from `mcp_fail` (it was `0`).
- **`mcp_error`, `mcp_result_error` and `mcp_fail_invalid_args` are removed**: use `mcp_fail --type TYPE MESSAGE [--hint TEXT] [--data JSON]`, which ends the tool (`mcp_error` and `mcp_result_error` did not, and sent a `{success: false, error}` envelope as `structuredContent`). `mcp-bash migrate --write` rewrites `mcp_error` when an unconditional `exit` is the very next command (on the next line, or right after `;` on the same one; not inside a one-line function) and `mcp_fail_invalid_args`; `mcp_result_error` is reported for a manual change. A tool whose own script still calls a removed helper (as a command, not in a string or comment) doesn't run: the call returns an error result of type `migration_required` naming the helper, with a hint to run `mcp-bash migrate`. A removed helper called from another script the tool sources fails with "command not found", and the error result's hint names it. <!-- lint-api-usage: allow -->
- **`mcp_result_success`, `mcp_emit_text` and `mcp_emit_json` are removed**: use `mcp_result_json JSON` (its `structuredContent` is the data itself, with no `{success, result}` envelope) or `mcp_result_text TEXT`. `mcp-bash migrate --write` rewrites `mcp_result_success` together with the tool's envelope-shaped `outputSchema` and reports UI code that reads `.result`; the emit helpers are reported for a manual change. A tool that still calls them gets the `migration_required` result described above. <!-- lint-api-usage: allow -->
- **`mcp_result_text_with_resource` is removed**: add `--resource PATH [--mime TYPE] [--uri URI]` (repeatable) to `mcp_result_json` or `mcp_result_text` instead (its `--path` is now `--resource`). `mcp-bash migrate --write` rewrites it, continuation lines included, together with the tool's envelope `outputSchema`. <!-- lint-api-usage: allow -->
- **`mcp_result_with_ui` and `mcp_result_with_ui_data` are removed**: use `mcp_result_ui TEXT [DATA]` (their first argument, a resource URI, was ignored). `mcp-bash migrate --write` rewrites calls whose first argument is `""`; a non-empty one is reported for a manual change. <!-- lint-api-usage: allow -->
- **More kinds of broken `server.d/policy.sh` refuse every tool call**: since 1.9.5 an insecure `policy.sh` or one with a syntax error gets every call refused. 2.0 adds a `policy.sh` that stops while loading: a top-level command that fails (under `set -euo pipefail`), a syntax error in a file it sources, or a top-level `exit`, which on bash 3.2 or with `exit` left `tools/call` without an answer. The refusal is a `policy_denied` result naming the reason, and the instructions say so too. To find out, the server sources the file in a separate bash process at each start, so its top-level code runs once more then, and a slow top level delays `initialize`.
- **`tools/list` leaves out tools the operator's allowlist blocks**: a tool `MCPBASH_TOOL_ALLOWLIST` doesn't allow (or every tool, when it is unset and `MCPBASH_TOOL_ALLOW_DEFAULT` isn't `allow`) is no longer listed, and `_meta["mcpbash/total"]` counts the listed tools; calling one still gets the `policy_denied` result. The `initialize` and `server/discover` instructions say "Tools outside the server operator's allowlist (MCPBASH_TOOL_ALLOWLIST) are not listed and can't be called." (from the environment, without loading the registry), a warning log message gives the number of unlisted tools once per server (their names aren't sent to the client), and `mcp-bash doctor` shows the effective allowlist and names them. The project hook (`mcp_tools_policy_project`) takes the call's arguments, so it applies at call time only.
- **The 1.x policy hook `mcp_tools_policy_check` fails closed**: 2.0 always runs the built-in policy (the operator's deny-by-default `MCPBASH_TOOL_ALLOWLIST` and the tool path checks) first, then the restrict-only `mcp_tools_policy_project` from `server.d/policy.sh`. A `policy.sh` that still defines `mcp_tools_policy_check`, which replaced the built-in check in 1.x, gets every tool call refused with an error result of type `migration_required` that says what to change; the `initialize` and `server/discover` instructions and stderr say so too, and `mcp-bash validate`/`doctor` report it as an error. Skipping the old hook instead would drop the project's own restrictions. Rename it to `mcp_tools_policy_project`, remove its `mcp_tools_policy_check_default` call and read the call arguments from `$2` (they were `$3`; there is no metadata argument); `mcp-bash migrate --write` does this when the body uses only `$1`, and reports any other hook for a manual change. The fail-open fallback that allowed every call when the policy library was missing is gone too. <!-- lint-api-usage: allow -->
- **`MCPBASH_COMPAT_BATCHES` is removed**: JSON-RPC batch arrays stay automatic for protocol `2025-03-26`, which has them, and are rejected on every newer protocol whatever the variable says. `mcp-bash migrate` reports the variable where a project sets it. <!-- lint-api-usage: allow -->
- **Tool results no longer carry a top-level `name`**: the server added the tool's name to every `tools/call` result (and to `mcp-bash run-tool` output). It isn't part of the MCP schema. Scripts that pick `run-tool` output with `select(.name == …)` need another selector, such as `select(has("content"))`; `mcp-bash migrate` points them out.
- **A result's flat `_meta["ui/resourceUri"]` is no longer rewritten**: 1.x moved it to `_meta.ui.resourceUri` (the MCP Apps form) on every tool result; 2.0 sends `_meta` as the tool printed it. Put the URI in `_meta.ui.resourceUri`, or use `mcp_result_ui`; `mcp-bash migrate` lists scripts that still write the flat key. This also saves a `jq` process on every call.
- **Legacy clients get object `structuredContent` only**: for protocols before 2026-07-28, which require `structuredContent` to be an object, a tool that prints a JSON array, string or number now gets a text-only result (the JSON as the text), and a non-object `structuredContent` in a `CallToolResult` the tool printed itself is dropped. An `outputSchema` without a `type` is advertised to them with `"type": "object"`, which those versions require. A tool whose `outputSchema` declares another `type` doesn't advertise it to those clients, and its output isn't checked against it; `mcp-bash validate` warns about such schemas. Clients on 2026-07-28 (`MCPBASH_MODERN_PROTOCOL=true`) get any JSON value. Minimal mode, which has no JSON tool, can't tell objects from other values.
- **Completion scripts get `MCP_COMPLETION_ARGS_FILE` instead of `MCP_COMPLETION_ARGS_JSON`**: the request arguments (`query`/`prefix`, `argument`, `ref`, `context.arguments`) are now in a JSON file whose path is in `MCP_COMPLETION_ARGS_FILE`, for every completion script (registered, prompt and resource). Read it with `jq … <"$MCP_COMPLETION_ARGS_FILE"`. The file is removed when the script ends, so the path is valid only while it runs. The env var is gone: it is client-supplied, and over 128 KiB Linux refused to start the script. **A script not yet migrated fails silently**: one that reads `MCP_COMPLETION_ARGS_JSON` with a fallback to empty, as the 1.x scaffold and examples do, still answers, but with every suggestion, unfiltered by what the user typed, and no error. Run `mcp-bash migrate` (or `mcp-bash validate`) before upgrading a project with completion scripts: both list the scripts to change.
- **Prompt completion scripts get `MCP_PROMPT_METADATA_FILE` instead of `MCP_PROMPT_METADATA`**: the prompt's metadata is in a JSON file. A prompt with a large local icon (inlined as a data URI) made its completion script fail to start on Linux.
- **Resource completion scripts get `MCP_RESOURCE_METADATA_FILE` instead of `MCP_RESOURCE_METADATA`**: the resource's or template's metadata is in a JSON file, for the same reason.
- **Resource providers get `MCP_RESOURCE_TEMPLATE_VARS_FILE` instead of `MCP_RESOURCE_TEMPLATE_VARS`**: on a template match the matched values (from the client's URI) are in a JSON file. `MCP_RESOURCE_TEMPLATE_NAME` is unchanged. A value the host sets for any of the new `*_FILE` names is cleared at startup, like the template variables.
- **The `mcp_elicit_*` question helpers are called directly and answer with their exit code**: `mcp_elicit_confirm`, `mcp_elicit_string`, `mcp_elicit_choice`, `mcp_elicit_titled_choice`, `mcp_elicit_multi_choice`, `mcp_elicit_titled_multi_choice` and `mcp_elicit_url` no longer print the `{"action": ...}` JSON. They exit 0 when the user accepted (for `mcp_elicit_confirm`: accepted and confirmed) and 1 otherwise, with the reason in `MCP_ELICIT_ACTION` (`decline`, `cancel`, `unavailable`); `-v VAR` puts the answer in `VAR` (a compact JSON array for the multi-choice helpers). Answers are checked: a choice must be one of the options offered and of the right type, or it is `unavailable`. **A 1.x tool that captures them fails silently**: `resp="$(mcp_elicit_confirm …)" || true` followed by a check of `.action` gets an empty capture, so the "not accepted" branch runs even when the user said yes, with no error. Run `mcp-bash migrate` (or `mcp-bash validate`, which marks these findings as failing silently) before upgrading: rule `2-elicit-capture` lists every capture, and rule `2-elicit-bare` the bare calls that a "no" would now end under `set -e`. The rewrite: <!-- lint-api-usage: allow -->
  ```bash
  # 1.x
  resp="$(mcp_elicit_confirm "Delete 40 files?")" || true   # lint-api-usage: allow
  [ "$(jq -r .action <<<"$resp")" = accept ] && [ "$(jq -r .content.confirmed <<<"$resp")" = true ] || mcp_fail --type declined "Not confirmed"
  # 2.0
  mcp_elicit_confirm "Delete 40 files?" || mcp_fail --type declined "Not confirmed (${MCP_ELICIT_ACTION})"
  ```
- **`mcp_elicit` reports `unavailable` when no answer came back**: the raw helper, which still prints the client's JSON answer, printed `{"action":"error"}` on a timeout or a missing elicitation setup, and `{"action":"decline"}` when the client can't elicit; both are now `{"action":"unavailable"}`. A tool that told "the user declined" from "the client can't ask" by `decline` must check `unavailable`. `mcp_elicit_url_raw` (new) behaves the same for URL mode.

### Added
- **`-v VAR` and `--arg NAME` on the question helpers**: `-v VAR` puts the answer in a variable (helpers are called directly, so it reaches the tool); `--arg NAME` answers from the tool's argument `NAME` when the call has it, without asking: for clients that can't ask (Claude Desktop extensions), scripts and CI. A value that isn't one of the choices, or of the right type, is ignored and the user is asked. `mcp_elicit_confirm` reads `--arg` only when the client can't ask: a client that can always asks the user. Where it can't (Claude Desktop extensions, scripts, CI), the argument is still the model's answer. The arguments come from the model: don't use `--arg` on a destructive confirmation. `mcp_elicit_url_raw` prints the client's JSON answer for URL mode, like `mcp_elicit` does for forms.
- **`mcp-bash validate` marks deprecations that fail silently in 2.0**: a finding of a rule whose 1.x code keeps running in 2.0 but takes the wrong branch with no error (`2-elicit-capture`, `2-completion-env`) is shown with ✗ and "fails silently in 2.0", the output ends with a line counting them, and `--json` gives each deprecation `"silent": true|false`. Deprecations, silent ones included, still don't change the exit status; `--deprecations-as-errors` does. New `migrate` rule `2-elicit-bare` reports bare question-helper calls in scripts that use `set -e`, and `2-elicit-capture` now covers every way 1.x code read their output (`$(...)`, backticks, a pipe into jq) and no longer flags the raw `mcp_elicit`, which still prints JSON.
- **Embedded resources on the result helpers**: `mcp_result_json` and `mcp_result_text` take `--resource PATH [--mime TYPE] [--uri URI]` (repeatable). Without it their output is unchanged. An option they don't know (such as a leftover `--path`) is ignored with a warning on stderr. A file is attached only to a successful result: invalid JSON passed to `mcp_result_json` gives the `internal` error result without it.
- **`mcp_result_ui TEXT [DATA]`**: the result helper for tools with an MCP Apps UI. A client with the UI extension gets `DATA` as `structuredContent`; any other client gets the text. A `DATA` that isn't a single JSON value gives an `internal` error result, for every client.
- **`mcp-bash migrate`** rewrites `mcp_result_with_ui[_data] "" ...` to `mcp_result_ui` and `mcp_result_text_with_resource` to `mcp_result_json --resource` (a call whose result is captured with `$(...)`, that forwards `"$@"` or that has `--path` inside a quoted string is reported for a manual change), drops an unwrapped `outputSchema` description that mentions `success`, and reports hand-built results that put a `{success, ...}` envelope in `structuredContent`. <!-- lint-api-usage: allow -->
- **`mcp-bash migrate` finds scripts that read the removed completion and template variables** (`MCP_COMPLETION_ARGS_JSON`, `MCP_PROMPT_METADATA`, `MCP_RESOURCE_METADATA`, `MCP_RESOURCE_TEMPLATE_VARS`), in `.sh` files, `*.completion` scripts and the completion scripts `server.d/register.json` lists (whatever their extension). It reports them for a manual fix (`--explain 2-completion-env` shows the one-line replacement).
- **`mcp_fail` without `--type`**: `mcp_fail MESSAGE [--hint TEXT] [--data JSON]` ends the tool with an error result of type `tool_failed`; `mcp_fail -- MESSAGE` takes the message literally (a number, or text starting with `--`). Arguments after the message other than `--hint` and `--data` are ignored, with a note on stderr.
- **`mcp-bash migrate --write` invalidates the tools cache** when it changes a file (`tools.json`, plus the startup scan's findings and record in `scan/`, in the registry dir), and says so. A copy the project tracks in git is expired instead of deleted; the other registry files are left alone. A server restarted within the cache TTL otherwise kept checking results against the `outputSchema` migrate had just rewritten. `--json` reports it as `registryCacheCleared`.
- **Instructions note about removed SDK helpers**: the startup scan (in the background) now also runs when a project file or the framework's rules changed since the last scan, at most once an hour per project, and right after the framework is upgraded, and lists the project files that call an SDK helper removed in 2.0 in `scan/removed-api.findings` in the registry dir (the `scan/` directory ignores itself in git). When that file is non-empty, `initialize` and `server/discover` append a sentence to the instructions naming those files (up to three) and saying the tools that use them return an error until they are migrated (`mcp-bash migrate` lists the changes). The note reflects the previous start's scan, so it appears from the second start on; `mcp-bash migrate --write` deletes the file. It is never sent where the scan can't run (bundles with a static registry, minimal mode, a vendored runtime without the rule engine, a read-only registry dir) or is turned off (`MCPBASH_DEPRECATION_NOTICE=false`), and `mcp-bash bundle` leaves the file, the scan record and the notice stamp out of the bundle. A start that doesn't scan costs four short-lived processes in the background; outside the once-a-day stderr line only the removed-helper rules run. <!-- lint-api-usage: allow -->
- **MCP 2026-07-28, opt-in (`MCPBASH_MODERN_PROTOCOL=true`)**: the server serves stateless 2026-07-28 requests (protocol version and client capabilities in each request's `_meta`, no `initialize`) next to the legacy `initialize` session, in the same process, and answers `server/discover`. Results carry `resultType`, `_meta["io.modelcontextprotocol/serverInfo"]` and, on discover, the lists and `resources/read`, the caching hints `ttlMs`/`cacheScope` (`MCPBASH_MODERN_LIST_TTL_MS`, `MCPBASH_MODERN_READ_TTL_MS`, `MCPBASH_MODERN_CACHE_SCOPE`). A modern request gets `-32022` for an unsupported version, `-32601` for methods 2026-07-28 removed (`ping`, `logging/setLevel`, `resources/subscribe`, ...), `-32602` for a missing resource, and log notifications only when it sets `_meta["io.modelcontextprotocol/logLevel"]`. A tool can return any JSON value with `mcp_result_json` to a modern request. **Off by default**: on this path the server can't yet ask the client for roots or elicitation, or send list-change notifications, so a client that goes modern (Claude Code does when `server/discover` succeeds) would get less than from the legacy session. With the switch off, `server/discover` stays "Method not found" and nothing changes.

### Fixed
- **The KILL after a cancel, a timeout or an abnormal exit could reach another process group**: a second after the TERM (on a cancel, a timeout, a signal or failed write that ends the server, or from the helper that cleans up after a killed server), the server sends KILL to the tool's process group. If that group had ended and its id had been given to a new group in the meantime, the KILL reached the new one. The server now notes the group's leader at the TERM (its start time) and skips the KILL when another process holds the group id by then. Everything else is signalled as before, including what a tool's TERM handler starts on its way out.
- **Tools kept running after the server was killed with SIGKILL**: a server killed without a chance to clean up (SIGKILL, a crash) left its running tools, completion scripts and providers behind, and its state directory too; a host that never reaps the killed server (so it stays a zombie) was no different. A small helper started with the first request that runs in a worker now notices the server is gone within about 5 seconds, stops what it started (TERM, then KILL) and removes the state directory, as the server does when it exits normally.
- **`examples/09-registry-overrides` failed its own tool call**: `server.d/register.json` still declared the `{success, result}` envelope as the `outputSchema` of `manual.progress`, whose script uses `mcp_result_json`, so every call got `output_schema`. The schema describes the data now. `mcp-bash migrate` does not read `register.json`; update an envelope schema there by hand.

## [1.9.6] - 2026-10-14

### Behaviour changes to check before upgrading
- **`server.d/policy.sh` is test-loaded once at every server start, so its top-level code runs one extra time**: to catch a `policy.sh` that dies while it is loaded, the server sources it in a separate bash process at each start, before any call. Anything its top level does outside its functions (writing files, network calls, output) now happens twice per start, and a slow top level delays the server's first answer. Keep `policy.sh` to function definitions and plain assignments.
- **Tool calls are refused when `policy.sh` dies while it is loaded**: a top-level command that fails, a syntax error in a file `policy.sh` sources, or a top-level `exit`. Before, a syntax error in a sourced file could leave the project's hook undefined on bash 4+, so the tool ran without the project's restrictions; a failing top-level command or an `exit` ended the call with no response. Now the call gets an error result naming the reason, and the reason is printed on stderr at startup.
- **Calls are refused when a file `policy.sh` sources breaks while the server runs**, if the project's hook (`mcp_tools_policy_project`, or a `mcp_tools_policy_check` that replaces the built-in check) is then no longer defined. Other mid-run breaks are caught at the next start: restart the server after editing files `policy.sh` sources.

### Changed
- `test_exit_stops_tools.sh` waits up to 30 s for its tool to start (it timed out under load).

## [1.9.5] - 2026-10-14

### Behaviour changes to check before upgrading
- **Tool calls are refused while `server.d/policy.sh` can't be loaded safely**: the server refuses to source a `policy.sh` that it, `server.d` or the project root lets group or other users write, that is a symlink or that you don't own, or that has a syntax error. Before, it then ran without it: the operator allowlist still applied, but the project's own restrictions (a read-only mode, say) were silently dropped, the warning reached only the log, and with a syntax error bash 3.2 stopped the call with no response. Now every tool call gets an error result naming the file, the reason and the fix (for example `chmod go-w`), and the reason is printed on stderr at startup. Projects whose directories are group-writable (a `umask` of `002`, common on Ubuntu and Debian) must fix the permissions.

## [1.9.4] - 2026-10-14

### Fixed
- **The server stopped at startup in CI mode when `TMPDIR` was unset**: with `MCPBASH_CI_MODE=true` outside GitHub Actions (no `RUNNER_TEMP` or `GITHUB_WORKSPACE`), for example in a Docker container, bash 4 and later stopped with "TMPDIR: unbound variable", because the temp-root default was a malformed expansion. It now uses `TMPDIR` without its trailing slash, or `/tmp`. Bash 3.2 was not stopped but got an empty root, which a later fallback replaced.
- **`mcp-bash run-tool` put a log line in the result for a resource outside the roots**: the warning that names the skipped path and the allowed roots was written to the same stdout as the resource, and became a `{"type":"resource"}` block holding the log notification. Only resource objects are embedded now. Over stdio the server was not affected.

## [1.9.3] - 2026-10-13

### Fixed
- **Tool log messages never arrived with live progress on**: with `MCPBASH_ENABLE_LIVE_PROGRESS=true`, the server flushed a tool's log stream from the wrong file name (`log.<key>.ndjson` instead of `logs.<key>.ndjson`), so `mcp_log` notifications from tools never reached the client. Fixing that exposed a race: the background flusher and the worker's final flush could both send the same progress or log line. Each stream's flush now holds a lock, and sends exactly the bytes it measured and only complete lines (a line the tool appended while the flush ran, or a line still being written, waits for the next flush), so every line is sent once.
- **`mcp_client_supports_ui` was always false inside tools**: the SDK reads `MCPBASH_CLIENT_SUPPORTS_UI` or a file in the server's state directory, but the server passed neither to tools. So `mcp_result_with_ui` always sent its text fallback, even to a client that declared the MCP Apps extension (`io.modelcontextprotocol/ui`). The server now sets `MCPBASH_CLIENT_SUPPORTS_UI` (`1` or `0`) for each tool call.
- **A tool's stderr with bytes that aren't valid UTF-8 was cut short on macOS**: in a UTF-8 locale, BSD `tr` stops at the first byte that isn't valid UTF-8, so `_meta.stderr`, the error message of a failed tool and `error.data.stderrTail` ended there, and the server logged "tr: Illegal byte sequence". Those `tr` calls now run in the C locale; the bytes reach the client as U+FFFD.

## [1.9.2] - 2026-10-13

### Behaviour changes to check before upgrading
- **Error results from tools with an `outputSchema` have no `structuredContent`**: when a tool that declares an `outputSchema` returns an error result carrying `structuredContent` (the `{success: false, error}` envelope from `mcp_error` and `mcp_result_error`, or JSON output with a non-zero exit), the server now drops `structuredContent` and moves the envelope's `error` to `_meta["mcpbash/error"]` (`type`, `message`, `hint`, and `data`, or the error's other fields as `data`). The TypeScript SDK client, which Claude Desktop uses, checks `structuredContent` against the `outputSchema` on error results too, so those errors failed in Desktop instead of reaching the model. The text content is unchanged. Tools without an `outputSchema` are unchanged. <!-- lint-api-usage: allow -->

### Fixed
- **A new server served the registry cache an earlier run left behind**: a server that loaded `.registry/tools.json` (or the prompts, resources or templates cache) at startup treated it as scanned at that moment, so for the first TTL seconds (5 by default) it served the cached definitions, however old. That is when a client lists and makes its first call: after a tool's `outputSchema` changed, its first call failed with "Tool output does not satisfy outputSchema", and the change only showed up after a later rescan sent `list_changed`. A loaded cache is now dated by its file's modification time, so one older than the TTL, or dated in the future (a copied or extracted project, clock skew), is rescanned first.

## [1.9.1] - 2026-10-12

### Behaviour changes to check before upgrading
- **A tool timeout is an error result like any other**: a timed-out tool now returns the same shape as `mcp_fail` and policy denials: `isError: true`, no `structuredContent`, and `_meta["mcpbash/error"]` with `type: "timeout"`, `message`, `hint` (the tool's `timeoutHint`) and `data` (`reason`, `timeoutSecs`, `exitCode`, and `progressExtendsTimeout`/`maxTimeoutSecs` when progress-aware timeout is on). `_meta.exitCode` and `_meta.stderr` are unchanged. Before, the details were in `structuredContent` as `{success: false, error: {...}}`, which a tool's `outputSchema` doesn't describe, and the hint followed `Suggestion:` in the text (now `Hint:`). Clients that read `structuredContent.error.type` or `.reason` on a timeout should read `_meta["mcpbash/error"].type` and `.data.reason`.

### Fixed
- **Reading a resource by URI could report it missing when two resources share the URI**: lookups by name or URI piped every match into `head -n 1`. With large registry entries, `head` could exit while jq was still writing the second match; jq was then stopped by SIGPIPE and the lookup reported "not found". Tool, prompt, resource and completion lookups now take the first match in jq itself.
- **Timeouts without jq carry the error details**: in minimal mode (no jq/gojq) a timeout result had only the message; it now has `_meta["mcpbash/error"]` and `_meta.exitCode` too.

## [1.9.0] - 2026-10-12

### Behaviour changes to check before upgrading
- **`resources/read` has a default timeout of 120 seconds**: a provider that takes longer is stopped and the client gets a `-32603` error. Before, a read had no limit unless the client sent `timeoutSecs`. Set `MCPBASH_DEFAULT_RESOURCE_TIMEOUT` to raise it, or to `0` to turn it off.
- **Tools are stopped when the server stops abnormally**: when the server exits on a signal (SIGTERM, SIGINT or SIGHUP, for example when the host quits), because the client stopped reading, because its parent died, or on a fatal error, tools still running get TERM, then KILL after 1 second. This also applies after `shutdown` when the client keeps the input open longer than `MCPBASH_SHUTDOWN_TIMEOUT` (5 seconds by default). Before, they ran on until they finished, and after the server's parent died it waited for them first. A normal end of input still waits for running tools. A tool with side effects that must not be interrupted should handle TERM and finish quickly, or be safe to rerun.
- **Static resources without `provider` get one by the same rule everywhere**: auto-discovery, `register.sh` (`mcp_register_resource` or printed JSON) and `register.json` now agree. `file://`, `git+https://`, `https://`, `ui://` and the bundled demo `echo://` use the built-in provider; any other scheme uses `providers/<scheme>.sh` when it exists; otherwise `file`, with a warning at registration. Before, `register.sh` sent `ui://` and custom schemes to `file`, and printed JSON had no provider at all. `register.json` named a provider after any scheme even if no script existed; such resources now use `file` and log the warning (their reads failed before too). Resources that set `provider` are unchanged.
- **Resource templates that already set `provider` start using it**: a template with a `provider` key (ignored until now) that names an existing `providers/<name>.sh` now routes the URIs it matches to that provider. Other existing `provider` values keep today's routing and now log a warning.
- **A `MCPBASH_STATE_DIR` or `MCPBASH_LOCK_ROOT` you set is never removed**: as documented. Before, one named like the server's own temp directories under `MCPBASH_TMP_ROOT` (`mcpbash.state.*`, and for the lock root also `mcpbash.locks*` or `mcpbash.bootstrap.*`) was deleted on exit. If you relied on that, clean it up yourself or leave the variable unset.
- **A failed write to stdout stops the server**: when any write to the client fails (the client stopped reading), the server now exits at once with status 143 and stops running tools, including when the write was a tool's result. Before, only a failed write in the main loop stopped it (status 1), and a failure in a tool worker left the server running with no one reading. `MCPBASH_ALLOW_CORRUPT_STDOUT=true` no longer keeps the server running after a failed write; it only lifts the corruption limit.
- **The stdout corruption limit is enforced**: `MCPBASH_CORRUPTION_THRESHOLD` events within `MCPBASH_CORRUPTION_WINDOW` (3 in 60 seconds by default) now stop the server (status 143), also when they happen in a tool worker. Before, a counting bug meant the limit never applied as documented.
- **Requests that time out now get an error response**: a `resources/*`, `prompts/get`, `completion/complete` or `tools/list` request that hits its timeout gets `-32603` "<method> timed out after Ns". Before, it got no response at all, so a client waiting on it hung.

### Added
- **Resource templates can name their provider**: a URI whose best-matching template sets `provider` is read by that provider; otherwise the URI scheme decides, as before. The provider must be a project provider (`providers/<name>.sh`) or a built-in on its own scheme (`file` on `file://`, `ui` on `ui://`, ...), on a template the matcher supports. Anything else is dropped with a warning at registration, and `mcp-bash validate` reports it. `resources/templates/list` never shows `provider`.
- **`MCPBASH_LOCK_REAP_GUARD_STALE_SECS`** (default `5`): how old an internal lock-reaper guard must be before it is treated as abandoned.
- **Alpine (BusyBox) CI job**: the unit and integration suites also run on Alpine Linux, where `ps`, `stat`, `find`, `tar` and `date` are BusyBox; `test/ci-alpine.sh` runs the same thing locally with Docker.
- **Claude Code skill 0.4.1**: the `mcp-bash` plugin's skill covers the 1.9 traps for server authors (resource timeouts, tools stopped on exit, template providers, read-only project directories, tool names that start with `-`).
- **Conformance test against the official MCP schemas**: an integration test validates server output against the official MCP JSON schemas for 2024-11-05, 2025-03-26, 2025-06-18 and 2025-11-25 (vendored in `test/conformance/schemas`).

### Fixed
- **`--help` works for `scaffold`, `registry` and `debug`, and never becomes a name**: `mcp-bash scaffold prompt --help` (also `resource` and `completion`) created a prompt, resource or completion literally named `--help`; `scaffold tool --help` and `scaffold ui --help` failed. They now print the scaffold help, and names starting with a dash are refused. `scaffold --help` and `registry --help` print their own help instead of the general one, and `debug --help` prints help instead of starting a server. The general help lists `validate --deprecations-as-errors` and `--health`'s `--project-root`/`--timeout`.
- **Timeouts and cancellation stop a tool's child processes on BusyBox systems (Alpine)**: BusyBox `ps` has no `-p`, so the server could not look up a worker's process group and took the worker for an isolated group leader. Signals then reached only the worker, and the processes a tool or provider started kept running after a timeout or cancel. Process groups are now read from `/proc` on Linux, and the child-process fallback works with BusyBox `ps`.
- **`run-tool` on BusyBox systems (Alpine) sees a tool changed right after the last run**: BusyBox `find` compares whole seconds, so a tool added or edited in the same second the registry cache was written was missed until the next change.
- **`run-tool` no longer misses a newer tool at random on BusyBox systems**: the check for files newer than the registry cache stops at the first match, which could kill `find` with SIGPIPE, and the failed pipeline discarded the match it had already found. When the second, same-second check missed it too, a tool added since the last run was reported as "tool not found". This was rare, and seen only on Alpine.
- **No warning on exit for a state or lock directory you set yourself**: with `MCPBASH_STATE_DIR` or `MCPBASH_LOCK_ROOT` pointing outside the temp root, every exit printed "refusing to remove … outside TMP root". The directory is still left in place; the message is gone.
- **bash 3.2: a tool cancelled or timed out while writing no longer blocks all later output**: bash 3.2 has no `$BASHPID`, so every worker recorded the server's own pid as the owner of the output lock. A worker killed while holding it left a lock whose owner looked alive forever, and every later response waited on it. Locks now record the real process id on bash 3.2 too (at the cost of one short `sh` call per lock operation).
- **Resource size limits can't be turned off by a typo, and `file://` reads stop at the limit**: a `MCPBASH_MAX_UI_RESOURCE_BYTES` such as `1M` or `-1` disabled the limit; it now means the default. `ui://` reads ignored a custom `MCPBASH_MAX_UI_RESOURCE_BYTES` altogether and always used 1 MiB. `file://` reads copied the whole file before the size check, so a multi-gigabyte file filled the temp directory; the read now stops at `MCPBASH_MAX_RESOURCE_BYTES`. An oversized `file://` read now fails with "file provider: file exceeds N bytes" (still `-32603`). A read that failed partway returned the partial content as a success; it is now an error.
- **The `nslookup` and `dig` fallbacks read their answers correctly**: on systems without `getent`, `dscacheutil` and `host`, `nslookup` lost the first address (a host with one address was refused as unresolvable) and ignored the numbered `Address 1:` lines of BusyBox builds before 1.28, and a `dig` timeout message was taken for an IPv6 address (reported as a blocked host instead of a failed lookup). Both still refused rather than fetching anything unvetted.
- **Subscribing again right after unsubscribing keeps the new subscription**: for subscribe, unsubscribe, subscribe on one resource sent back to back, the unsubscribe could run last and remove the second subscription too, so its updates never arrived. An unsubscribe now removes only subscriptions requested before it.
- **Background helpers exit when the server is killed, even before the host reaps it**: the progress flusher and subscription poller checked only that the server's process existed, which is still true while a killed server waits to be reaped. They kept running and held the server's stdout open, so a host that reads to end of file before reaping could wait forever.
- **`mcp_args_require` accepts the string `"null"`**: an argument whose value was the text `null` was rejected as missing; only a missing argument, an empty string or a JSON `null` is rejected now.
- **Locks stay exclusive when several processes contend for them**: a waiter could remove a lock whose owner hadn't finished writing its pid file, so two processes could write to stdout together and interleave JSON-RPC lines, and a failed cleanup could stop a request with "Directory not empty". A waiter could also remove a lock just as another process took it, letting two processes hold it at once under heavy load. Lock helpers no longer print ownership warnings to stderr unless `MCPBASH_LOG_LEVEL=debug`.
- **Progress notifications leave out an unknown total**: they no longer send `"total": null` when the tool gives no total; the field is left out, as the MCP schema requires (`total` is a number).
- **URL-mode elicitation requests include `elicitationId`**: the MCP spec requires it; the server generates a unique one per request.
- **Resource read refusals say why**: when a resource provider refused a read (exit `2`), the error was always "Resource outside allowed roots", and the provider's own explanation was dropped. The provider's stderr text is now the error message when it wrote one, for example "cannot verify the opened file on this platform" from the file provider or "HTTPS provider blocked host …". A file read that fails because a directory on the way up to the root can't be checked is now reported as unverifiable, not as outside the roots.
- **`file://` and `ui://` reads on macOS no longer fail at random under load**: the check of the opened file stated `/dev/fd/N`, which macOS sometimes fails with "Bad file descriptor" while the file is open, so a valid read was refused as "cannot verify the opened file on this platform". The system `stat` (`/usr/bin/stat`) now checks the descriptor directly, even when GNU `stat` comes first on `PATH`, which also compares the file's real device (before, macOS compared its birth time in place of the device).
- **No more spurious "Cannot check for name collisions: resource registry unavailable" warning**: templates registered by `register.sh` or `register.json` were checked against the resources before the resources had been built, which logged this warning (twice with `register.json`). The check already runs again once the resources are known, and that check still drops a template whose name matches a resource.
- **The server stops when its client stops reading, even if only a tool was still answering**: a failed write in a tool worker ended only that worker, and the server kept running with no one reading (whether the host ignored SIGPIPE or not). It now stops and logs "the client stopped reading, shutting down"; see Behaviour changes.

### Documentation
- **`MCPBASH_CI_MODE` must be `true`**: `CONTRIBUTING.md` and `TESTING.md` said to set `MCPBASH_CI_MODE=1`, which the server ignores, so a local "CI mode" run tested real mode. They now say `true`, and the test harness turns `1` and `yes` into `true`.
- **OpenClaw and NanoClaw client recipes**: OpenClaw now keeps MCP servers in its own registry (`openclaw mcp add`, saved under `mcp.servers`), which does not read the mcporter config the README used to show. A new NanoClaw recipe mounts the framework and project into the agent's container, adds `jq`, and points the registry cache at a writable path.
- **README reorganised**: a short demo recording follows the TL;DR (re-record with `vhs scripts/demo/demo.tape`). Quick Start steps are numbered 1–6, and uninstalling (now including Homebrew) has its own section. The contents list covers every section. `jq` is listed as the preferred JSON tool, with a FAQ entry. The examples table includes 12–15 and `register-sh-hooks`. The features list covers elicitation, completions, MCP Apps and distribution, including `mcp-bash publish`. The documentation section links the full docs index and the MCP Apps, logging, inspector and environment guides.
- **README uninstall step no longer deletes your scripts**: step 3 said `rm -f /path/to/your/project/*.sh`, which removes every shell script in the project folder. It now removes only `<server-name>.sh`, the one file `mcp-bash config --wrapper` creates.
- Timeouts, resource size limits and exit behaviour are documented where readers look for them (`LIMITS.md`, `ERRORS.md`, the provider contract in `REGISTRY.md`, `ARCHITECTURE.md`, `DEBUGGING.md`, `llms-full.txt`); `SECURITY.md` no longer says `resources/read` has no timeout; `llms.txt` names the `mcp_tools_policy_project` hook.
- Fixed broken links and section numbers; completed the docs index and `llms.txt` (environment reference, errors, resource templates, elicitation, completion, MCP Apps, examples 10–14); documented `MCPBASH_TMP_ROOT`, `MCPBASH_STATE_DIR` and `MCPBASH_LOCK_ROOT` as operator settings; clarified that `MCPBASH_PROGRESS_EXTENDS_TIMEOUT` affects the per-tool timeout, not `MCPBASH_IDLE_TIMEOUT`; MCP Apps template status is now consistent (data-table ready, the rest experimental and host-dependent).

## [1.8.0] - 2026-10-11

### Behaviour changes to check before upgrading

- **Tool policy denials:** a call refused by `MCPBASH_TOOL_ALLOWLIST` or `server.d/policy.sh` now returns a tool result with `isError: true` and type `policy_denied` instead of a JSON-RPC error, and a policy's custom error code is no longer sent. `mcp-bash run-tool` output for a denial no longer contains the `_mcpToolError` marker: test harnesses that detect a refused call through that marker must check `.isError` instead (`run-tool` still exits 1).
- **Migrating to the frozen helpers:** `mcp-bash migrate --write` changes your tools, not your tests. Update your own tests that assert the `{success, result}` envelope or the `_mcpToolError` marker; `migrate` can't see them.
- **SDK argument helpers:** `mcp_args_require`, `mcp_args_int`, `mcp_args_bool`, `mcp_require_path` and `mcp_download_safe_or_fail` now report a missing or invalid argument as a tool error result (`isError: true`, `_meta["mcpbash/error"].type` = `invalid_args`) instead of a JSON-RPC `-32602` error. Tests or clients that expect `-32602` from these helpers must check `.result.isError` instead. `mcp_fail_invalid_args` itself still sends `-32602`.
- **Tools now receive SIGTERM on timeout and cancel:** tools used to run with SIGTERM ignored, so only SIGKILL stopped them. A tool's own `trap … TERM` now runs when its call times out or is cancelled, and gets about a second before SIGKILL.

### Changed

- **Argument helpers report errors the model can read**: a missing or invalid argument rejected by the SDK helpers was a JSON-RPC error, which Claude Desktop shows only as a generic connector error. It is now an `invalid_args` error result, so the model can read it and retry. Called inside `$(...)`, the helpers still deliver that result: it goes through the tool-error side channel, and the framework returns it as the tool's result. The script itself stops there only under `set -e`; without it, write `x="$(mcp_args_require '.x')" || exit 1`.
- **New projects use the frozen helpers**: `mcp-bash new`, `init` and `scaffold tool` generate tools that return `mcp_result_json` with an `outputSchema` describing the data itself, show `mcp_fail --type` for errors, and record `"mcpBash": {"apiVersion": 2}` in `server.meta.json`.
- **Examples and docs teach the frozen helpers**: BEST-PRACTICES adds "Migrating to the 2.0 helpers".
- **Policy denials are tool results, not JSON-RPC errors**: A `tools/call` refused by the tool allowlist or a `server.d/policy.sh` rule returned a JSON-RPC error, which Claude Desktop shows only as "The connector returned an error or an invalid response", so neither the model nor the user saw why. It is now a tool result with `isError: true`, the denial message as text and `_meta["mcpbash/error"]` = `{"type":"policy_denied","message":…}` (plus the policy's data, if any). A policy's custom error code (for example `-32600`) is no longer sent. A rejected tool path, a missing executable and inherit mode without the allow flag stay JSON-RPC errors. `mcp-bash run-tool` prints the result and still exits 1.

### Added

- **Startup notice for APIs that change in 2.0**: When a project uses APIs that change in mcp-bash 2.0, the server prints one line to stderr at startup, at most once a day per project, with the number of uses and a pointer to `mcp-bash validate`. The scan runs in the background and never writes to stdout. It is skipped for bundles (static registry), vendored runtimes, minimal mode and a read-only registry dir; `MCPBASH_DEPRECATION_NOTICE=false` turns it off.
- **`mcp-bash migrate`**: lists every use of an API that changes in 2.0 (check mode by default). `--write` applies the unambiguous rewrites into the frozen forms (`mcp_fail_invalid_args`/`mcp_fail -32602|-32603` → `mcp_fail --type`; `mcp_error` followed by `exit` → `mcp_fail --type`; `mcp_result_success` → `mcp_result_json` together with the tool's envelope-shaped `outputSchema`; a `policy.sh` hook that starts with the default check → `mcp_tools_policy_project`), then records `"mcpBash": {"apiVersion": 2}` once nothing else is pending. Anything ambiguous is listed as manual: captured `$(…)` output, `"$@"` forwarding, extra arguments, UI code reading `.result`, `mcp_result_error`. `--write` refuses a dirty git tree (unless `--force`) and a vendored `.mcp-bash` runtime older than these helpers (run `mcp-bash vendor --upgrade` first), and keeps `.bak` copies outside git. Exit status: 0 nothing pending, 1 automatic fixes pending, 2 manual work pending, 3 error. Also `--list`, `--explain ID`, `--only`, `--skip`, `--json`.
- **`mcp-bash validate` reports deprecations**: uses of APIs that change in 2.0 (`mcp_error`, `mcp_result_error`, `mcp_result_success`, `mcp_fail CODE …`, `mcp_fail_invalid_args`, `mcp_emit_*`, replacement-style `policy.sh` and others) are listed with file, line and a fix. They are counted separately from warnings, so `--strict` is unaffected; `--deprecations-as-errors` makes them fail validation. `--json` adds a `deprecations` count and one message per finding.
- **Frozen 2.0 result and error helpers**: `mcp_result_json JSON [--max-text-bytes N]` returns a result whose `structuredContent` is the JSON itself (no `{success, result}` envelope); the text block is the serialized JSON, or a short summary above N bytes, and on protocols before 2026-07-28 a non-object value is sent as text only. `mcp_result_text TEXT` returns a plain text result. `mcp_fail --type TYPE MESSAGE [--hint TEXT] [--data JSON]` ends the tool with an error result the model can read (`isError: true`, details under `_meta["mcpbash/error"]`), also when called inside `$(...)`, such as from a helper function whose output is captured: it exits non-zero and the framework returns the result as the tool's (the script stops there only under `set -e`; without it, add `|| exit 1`); the numeric `mcp_fail CODE MESSAGE` form is unchanged. These, `mcp_tool_error_result` and the `"mcpBash": {"apiVersion": 2}` marker in `server.meta.json` are frozen: they keep their name, arguments and output in mcp-bash 2.0, so code written with them now needs no change then.
- **`mcp_tools_policy_project` restrict-only policy hook**: `server.d/policy.sh` can define `mcp_tools_policy_project TOOL_NAME ARGS_JSON`, called after the built-in allowlist and path checks, so it can only narrow access. Exit 0 allows; any other status denies, and the hook's stdout becomes the denial message (trailing newlines dropped, capped at 1 KiB, `Tool '<name>' denied by server policy` when empty). It runs in a subshell so it can never write to the protocol stream; keep any state in files. Redefining `mcp_tools_policy_check` still works as before.

- **`mcp_tool_error_result` builds a tool error result**: `mcp_tool_error_result TYPE MESSAGE [--hint HINT] [--data JSON]` (in `sdk/tool-error.sh`, loaded by `tool-sdk.sh`) prints a result with `isError: true`, the message and hint as text the model reads, and the details under `_meta["mcpbash/error"]`, with no `structuredContent`. It is the shared shape for tool errors and policy denials. Existing helpers (`mcp_error`, `mcp_result_error`) are unchanged.

### Fixed

- **Timed-out and cancelled tools left processes running**: the tool wrapper ignored SIGTERM, and every process it started inherited that. A cancelled tool could keep running, and on timeout only the tool's own process was killed, so anything it started (for example a `sleep` or a `git` command) was left orphaned. Timeout now stops the tool and everything it started (TERM, then KILL after a second), and cancel stops the request's whole process group even when the worker exits first. A tool call with a timeout also no longer waits for the watchdog's next one-second tick after the tool finishes. Not on Git Bash, which has no process groups.
- **No file error on stderr after a cancel**: the delayed cancel cleanup no longer writes into the state directory of a server that has already exited.
- **Two examples kept going after rejecting their input**: `examples/04-roots-basics` read a file after rejecting its path as outside the allowed roots, and `examples/12-config-and-downloads` downloaded an `http://` URL after rejecting it. Both used `mcp_error`, which reports an error but doesn't end the tool; they now use `mcp_fail --type`.
- **A request split across the read timeout is answered**: With the timed read loop (the default outside CI mode), a request whose bytes arrived on both sides of the read timeout was lost. On bash 4+ each part was answered as a separate, unparseable message; on bash 3.2 the first part was discarded. The request itself was never answered, and the client waited indefinitely. The server now keeps the partial input and joins it with the rest (bash 4+), or reads the rest of a started line without a timeout (bash 3.2). A final request without a trailing newline is still answered when input ends.

## [1.7.0] - 2026-10-10

### Added

- **`mcp-bash doctor` warns when the git provider is enabled but git is missing**: With `MCPBASH_ENABLE_GIT_PROVIDER=true` and no `git` on `PATH`, every git resource read fails at fetch time. Doctor now warns (`git.missing` in `--json`).
- **Claude Code plugin with an mcp-bash skill**: The repository is now a plugin marketplace. `/plugin install mcp-bash --marketplace yaniv-golan/mcp-bash-framework` installs a skill that walks an agent through creating, testing, wiring and bundling an mcp-bash server, and lists the traps that fail silently (deny-by-default tools, `policy.sh`, the tool environment, bash 3.2 under Claude Desktop, completion script names).

### Security

- **Resources embedded in tool results can no longer be redirected by a symlink swap**: A tool's embedded resources (`MCP_TOOL_RESOURCES_FILE`, `mcp_result_text_with_resource`) were checked against the roots by path and then opened by name up to three times, for mime detection, the binary check and the content. Someone able to write inside a root could swap the file for a symlink after the check, and the tool result then carried the content of a file outside the roots. The file is now read once through the same verified read as `file://` resources, with the matched root, and detection and encoding use the bytes of that read. A file that isn't a regular file inside the roots when it is opened is skipped with a warning.

### Changed

- **Unknown methods before `initialize` get `-32601 Method not found`**: Newer clients, including Claude Code and Claude Desktop, probe with `server/discover` before `initialize` and fall back to `initialize` when it fails. The server answered every pre-`initialize` request it doesn't allow with `-32000 Server not initialized`, which some client versions handled badly. A method the server doesn't implement now gets `-32601`, and the server stays ready for `initialize`. Methods it does implement (for example `tools/list`) still get `-32000` before `initialize`.

### Fixed

- **Vendored runtimes and MCPB bundles include the whole SDK**: `mcp-bash vendor` and `mcp-bash bundle` copied only `sdk/tool-sdk.sh`, so `ui-sdk.sh` was missing and UI helpers such as `mcp_result_with_ui` did not exist in vendored and bundled projects. Every `sdk/*.sh` file is now embedded.
- **Cancellations no longer stall request handling**: Each `notifications/cancelled` sent TERM, then waited 1 second in the main loop before escalating to KILL. Cancels are handled one at a time, so N cancels delayed every other request, including `ping`, by N seconds. The escalation now runs in a background helper after the same grace period, and the server keeps answering at once.
- **Workers no longer spin when the server exits while they wait for a lock**: The lock root is inside the server's state directory, which cleanup removes on exit. A worker still waiting for a lock could then never create its lock directory and polled forever, starting a `sleep` every 20 ms. Lock waits now give up once the lock root is gone.
- **Error results are no longer checked against `outputSchema`**: A tool that declares an `outputSchema` and returns an error result (`mcp_result_error`, or any result with `isError: true`) got `-32603 Tool output does not satisfy outputSchema` instead of its own error, so the model never saw the reason. The schema describes successful structured results, and the MCP SDKs skip it for errors; error results are now returned as they are.
- **A fatal shell error in the server exits non-zero on bash 3.2**: Bash 3.2 reports status 0 to the EXIT trap after a fatal error such as an unbound variable, so the server exited 0 and hosts and CI saw success. Only the intended exits (end of input, `shutdown`/`exit`, idle timeout, orphan detection) now exit 0; any other zero status becomes 1.
- **SIGHUP stops the server, and INT/TERM stop it at any point**: The server's HUP trap, and its INT/TERM traps outside the read loop, ran cleanup without exiting, so the server kept running without its state directory. HUP, INT and TERM now exit with 129, 130 and 143 at any point after startup, and cleanup runs once. A signal while the server waits for running tools after stdin closes also cleans up.
- **The elicitation and ffmpeg-studio examples stop where they should**: The elicitation example (08) died under `set -e` when the client could not elicit; it now returns its own "Stopped" result. The ffmpeg-studio tools did not exit after an early error result, so `transcode` could continue to `ffprobe` and `ffmpeg -y` after an invalid preset or a declined overwrite, overwriting the file the user had refused to overwrite. `docs/ELICITATION.md` and `docs/BEST-PRACTICES.md` now show `|| true`, branching on `.action`, and that result helpers do not exit.
- **Built-in UI templates unwrap the `{success, result}` envelope**: The data-table, progress, diff-viewer, tree-view and kanban templates read the raw structured content, so a table fed by `mcp_result_success` rendered nothing. They now unwrap the envelope and still accept the old shape.
- **`mcp_result_with_ui` and `mcp_result_with_ui_data` work for clients without MCP Apps support**: They returned `isError: "Invalid JSON passed to mcp_result_success"` to every client without MCP Apps support; they now return the text fallback as a normal result. A UI result without data no longer sends `structuredContent: null`.
- **`mcp-bash run-tool` finds tools added or changed since the last scan**: A registry cache loaded from disk counted as fresh for the registry TTL from the moment it was loaded, so a one-shot `run-tool` never rescanned, and a tool added after the cache was written was reported as "tool not found" until `mcp-bash registry refresh` was run. `run-tool` now rescans when anything under the tools directory is newer than the cache, and reuses the cache otherwise. `--no-refresh` still uses the cache as written.
- **Clawdbot recipe renamed to OpenClaw**: Clawdbot is now OpenClaw and mcporter has moved to the openclaw organisation. The README recipe links to the new repositories and uses mcporter's current config shape (`mcpServers`, no `type` field); the config path `~/.mcporter/mcporter.json` is unchanged.
- **MCP Apps specification links work again**: The links to the MCP Apps extension spec in `docs/concepts/mcp-apps.md` and `docs/guides/ui-resources.md` returned 404; they now point at https://modelcontextprotocol.io/extensions/apps/overview.
- **`mcp_args_get --default` works**: The tool scaffold writes `mcp_args_get '.name' --default 'World'`, but `mcp_args_get` ignored the option, so every scaffolded tool returned the string `null` for a missing argument. `--default VALUE` is now used when the value is missing, null or an empty string (as `mcp_args_int` and `mcp_args_bool` do); `false`, `0` and the string `"null"` are kept. With `--default`, the helper also works in minimal mode. Tools copied from the scaffold are fixed without changes.
- **The installer test no longer changes the developer's `mcp-bash` command**: `test/integration/test_installer.sh` ran the installer with the real `HOME`, so each run pointed `~/.local/bin/mcp-bash` at a test directory that was deleted afterwards. It now uses a temporary `HOME`.

## [1.6.0] - 2026-10-10

### Behaviour changes to check before upgrading

Details are in the entries below.
- **Git provider** (opt-in, `MCPBASH_ENABLE_GIT_PROVIDER=true`): hostnames need git 2.37 or later; older git refuses them, since it can't be pinned to the checked address (`mcp-bash doctor` warns). It no longer follows HTTP redirects. LFS-tracked files are returned as pointer files.
- **URL ports:** the HTTPS and git providers refuse ports with leading zeros (`:080`) or out of range.
- **HTTPS and git providers:** a host that doesn't resolve is no longer fetched, and both providers refuse every request if `lib/policy.sh` can't be loaded.
- **Tool and provider environment:** only framework-owned `MCP_*` variables are passed by default, and `MCPBASH_REMOTE_TOKEN*` is never passed to tools or providers outside `inherit` mode (and is removed from tools' `_meta` in every mode). Add other names to the allowlist if a tool or provider needs them.
- **Resources:** a declared `mimeType` is reported as declared again, so resources scaffolded with `"mimeType": "text/plain"` report `text/plain`.
- **Completions:** registered completions without `timeoutSecs` time out after 30 seconds (`0` disables).
- **`initialize`:** a client asking for an unsupported protocol version now gets the latest supported version instead of an error; a non-string `protocolVersion` (e.g. `false`) now fails with `-32602`.
- **Runtime directories:** state and lock directories get random names; `${TMPDIR}/mcpbash.locks` is no longer used. A symlinked `MCPBASH_STATE_DIR`, `MCPBASH_LOCK_ROOT` or `MCPBASH_LOG_DIR` now stops startup.
- **`resources/unsubscribe`:** a request with neither `uri` nor `subscriptionId` now fails with "Resource uri required".

### Changed

- **`initialize` negotiates unsupported protocol versions instead of rejecting them**: Per MCP 2025-11-25 (Lifecycle, Version Negotiation: "Otherwise, the server MUST respond with another protocol version it supports"), a request for an unsupported version, older or newer, now succeeds with the latest supported version (2025-11-25), and the server logs a note to stderr. Previously it returned `-32602 Unsupported protocol version`. A missing or `null` `protocolVersion` still negotiates the default. A non-string value (for example `false` or `42`) returns `-32602` with `data: {supported, requested}`; `false` used to count as missing.
- **Runtime state directories have random names**: Per-process state directories, and the CI-mode default log directory, are created with `mktemp -d` (mode 0700), for example `mcpbash.state.<ppid>.<pid>.XXXXXX`. The lock root is now inside the state directory, and the shared CLI lock directory `${TMPDIR}/mcpbash.locks` is gone.
- **A declared resource `mimeType` is the reported label again**: `resources/read` reports a static resource's `mimeType` (from `.meta.json`, `register.sh` or `register.json`) as written. Since 0.x's binary detection, `file --mime` overrode it, so a `.md` declared `text/markdown` was reported as `text/plain`. This restores the pre-detection labels.
  - Detection still decides whether content is sent as `text` or a base64 `blob`: a `text/plain` label on a PDF is still a blob, and a declared `application/toml` stays text.
  - Resources without `mimeType` are labelled by detection, as before.
  - **Projects created with `mcp-bash scaffold resource` have `"mimeType": "text/plain"`** in their `.meta.json` and will now report `text/plain` even if the file holds JSON, Markdown, HTML or binary content. Remove the field or set the right type; `mcp-bash validate` warns when a declared type clearly disagrees with the file. New scaffolds no longer write `mimeType`.
  - `mcp_result_text_with_resource` without `--mime` no longer guesses a type (it fell back to `application/octet-stream`); the server detects it. With `--mime`, the value is reported as given.
  - After upgrading, registry hashes change for resources that declare `mimeType`: clients see one `notifications/resources/list_changed`, and earlier `resources/list` cursors become invalid.
- **Registered completions now time out by default**: Completions registered in `server.d/register.json` or `register.sh` that don't set `timeoutSecs` had no limit, so a hung script held a worker. They now time out after `MCPBASH_COMPLETION_REGISTERED_TIMEOUT_SECS` (default 30; `0` restores no limit). An explicit `timeoutSecs: 0` now means no timeout; it used to trip the watchdog after about a second. A negative or non-numeric `timeoutSecs` is rejected at registration with a warning and treated as unset; it used to fail the completion at run time.

### Security

- **HTTPS and git providers refuse non-canonical URL ports**: A port like `:000080` or `:0` made the providers pin port 443 while curl or git connected to the real port, unpinned. A port must now be plain decimal 1-65535 without leading zeros (exit 4, `host_blocked` in `mcp_download_safe`). Spellings such as `:080`, which worked before, are now refused too.
- **The git provider disables git-lfs downloads**: A cloned repository's `.lfsconfig` could send git-lfs, which makes its own HTTP requests outside the provider's pinning, protocol and redirect controls, to any URL. LFS-tracked files are now returned as pointer files.
- **`file://` and `ui://` reads can no longer be redirected by a symlink swap**: The providers checked the path for symlinks before and after reading, but never checked the file they actually opened. Someone able to write inside an allowed resource root could swap the file, or a directory above it, for a symlink mid-read and read files outside the roots. Reads now go through `lib/file_read.sh`. It pins the checked directory, confirms by inode that the directory is inside the matched root, and opens the file once. No bytes are returned unless the open descriptor is the regular, non-symlink file that was checked. If the platform can't identify the descriptor (no usable `stat` or `/dev/fd`), the read is refused. Known limits: a hard link inside a root to an outside file is still served; on macOS the file is identified by inode and birth time, which the file's owner can set; and a file swapped for a FIFO can block a read. See `docs/SECURITY.md`.
- **Static UI HTML is no longer served through a symlink pointing anywhere**: The UI registry read static HTML with no symlink check, so an `index.html` symlink to any file was served. It now uses the same verified read, and `MCPBASH_MAX_UI_RESOURCE_BYTES` now applies to it.
- **HTTPS and git providers check addresses more strictly and always pin the resolved address**: These checks matter when an operator has widened the host allowlist (`MCPBASH_HTTPS_ALLOW_ALL`, `MCPBASH_GIT_ALLOW_ALL` or broad allow lists).
  - **IPv4 literals must be canonical dotted quads.** Octal, hex, short and integer forms such as `0177.0.0.1`, `0x7f.0.0.1`, `127.1` and `2130706433` previously reached loopback; they are now refused.
  - **IPv6 literals are normalised before checking,** so `[0:0:0:0:0:0:0:1]`, `[::]` and full-form or hex v4-mapped loopback are blocked. NAT64, 6to4 and v4-compatible addresses are judged by their embedded IPv4 address. Teredo, documentation and other non-global IPv6 addresses are blocked.
  - **More blocked IPv4 ranges:** `0.0.0.0/8`, `100.64.0.0/10` (includes the `100.100.100.200` metadata endpoint), `192.0.0.0/24`, `198.18.0.0/15`, `224.0.0.0/4` and `240.0.0.0/4` (includes `255.255.255.255`). `*.localhost` names are blocked.
  - **Resolution fails closed.** A host that does not resolve is never fetched (exit 5), and every fetch is pinned to the checked addresses. On macOS the resolver now sees `/etc/hosts` and mDNS names (via `dscacheutil`); before, those names skipped both the private-range check and the pin.
  - **The git provider pins too,** via `http.curloptResolve`, and no longer follows redirects. This needs git 2.37 or later; older git is refused for hostnames.
  - **One private-range list** in `lib/policy.sh`, shared by both providers. If it can't be loaded, the providers refuse every request instead of falling back to their own, weaker copies.
  - **Still not covered:** behind an HTTPS proxy (`https_proxy`), the proxy resolves the host, so pinning has no effect. See `docs/SECURITY.md`.
- **Runtime directories can no longer be pre-planted by another local user**: State and lock directories used predictable names in the shared temp directory and were created with `mkdir -p`, which accepts a directory or symlink that already exists. They are now created with `mktemp -d`. Startup fails if `MCPBASH_STATE_DIR`, `MCPBASH_LOCK_ROOT` or `MCPBASH_LOG_DIR` is a symlink, and a `MCPBASH_STATE_DIR` that cannot be created is an error instead of being silently replaced. Cleanup never removes a symlink.
- **Tools and providers no longer receive the remote-access secret**: Outside `inherit` mode, `MCPBASH_REMOTE_TOKEN*` is removed from tool and provider environments, even when an allowlist names it. (A tool running as the same user can still read the server's own process environment; see `docs/SECURITY.md`.) The token's request `_meta` keys (`MCPBASH_REMOTE_TOKEN_KEY`, default `mcpbash/remoteToken`, and the fallback key) are deleted from the `_meta` passed to tools (`MCP_TOOL_META_JSON`/`MCP_TOOL_META_FILE`) in every mode. A `_meta` that is not a JSON object becomes `{}`. Behaviour change: a tool that read the token must get it another way.
- **Only framework-owned `MCP_*` variables reach tools and providers by default**: Previously every `MCP_*` variable passed, including user secrets such as `MCP_REGISTRY_TOKEN` (which `docs/MCPB.md` tells users to export). Now only `MCP_SDK`, `MCP_TOOL_*`, `MCP_ELICIT_*`, `MCP_PROGRESS_*`, `MCP_LOG_STREAM`, `MCP_CANCEL_FILE`, `MCP_ROOTS_*`, `MCP_RESOURCES_ROOTS`, `MCP_COMPLETION_*`, `MCP_PROMPT_*`, `MCP_RESOURCE_*`, `MCP_CONFIG_JSON`, `MCP_TRANSPORT` and `MCP_PATH_DEBUG` pass. Behaviour change: a tool or provider that reads its own `MCP_*` variable must name it in `MCPBASH_TOOL_ENV_ALLOWLIST`/`MCPBASH_PROVIDER_ENV_ALLOWLIST` (allowlist mode); `server.meta.json` `"env"` allowlists may now name such variables, while the framework families stay reserved.

### Added

- **Per-resource completion scripts work for resource templates**: A `completion/complete` with `ref/resource` was matched only against static resources by exact URI, so a template's completion script was never run and the server returned values built from the URI string. Claude Desktop sends `ref/resource` only for template arguments, so per-resource completions did nothing there. The URI is now also matched against the templates (exactly by `uriTemplate`, or as a concrete URI), and the script is found by template name: `resources/<name>.completion.sh` or `resources/<name>/<name>.completion.sh`. `MCP_RESOURCE_URI` is the `uriTemplate`, and `MCP_COMPLETION_ARGS_JSON` `.argument.name` names the variable being completed.
- **`mcp-bash doctor` warns when the git provider can't pin**: With `MCPBASH_ENABLE_GIT_PROVIDER=true` and git older than 2.37, doctor warns (`git.version_unpinnable` in `--json`) that fetches by hostname will be refused.
- **`resources/read` matches resource templates**: When no resource has the requested name or exact URI, the URI is matched against the registered resource templates.
  - **Syntax:** a subset of RFC 6570: `{v}` (stops at `/`, `?`, `#`), `{+v}` and `{#v}`. Templates using other operators, comma lists, modifiers, adjacent or repeated expressions keep their previous read behaviour.
  - **Ties:** the template with the most literal characters wins, then the fewest expressions, then the template name.
  - **What a match supplies:** the template's `mimeType` is reported as a declared label, and the provider receives `MCP_RESOURCE_TEMPLATE_NAME` and `MCP_RESOURCE_TEMPLATE_VARS` (compact JSON of the raw, not percent-decoded, values). Both variables are cleared at startup, so a host-set value never reaches other reads, tools or completion providers.
  - **Unchanged:** matching never changes which provider runs, and the `resources/templates/list` shape is unchanged.
- **`mcp-bash run-tool --print-env` shows the env policy**: It now prints the effective tool and provider env policy (mode and source per scope, allowlisted names and whether each is set) and never values. It covers the launch environment plus `server.meta.json` only, not `--with-server-env`/`--source` files or `server.d/policy.sh`, and says so.
- **Bundles log cleared placeholders at debug level**: With `MCPBASH_LOG_LEVEL=debug`, a bundle's `run-server.sh` writes the names (never values) of variables it unset because they still held an unexpanded `${user_config.*}` placeholder.

### Fixed

- **On bash 3.2, a disconnected client no longer leaves the server spinning**: When the host ignores SIGPIPE (as GUI hosts do) and the client goes away, the failed response write left its bytes in bash 3.2's output buffer. They leaked into later command output, and the server looped at full CPU instead of exiting.
- **`mcp-bash run-tool --source FILE` fails when FILE has a syntax error**: On bash 3.2 it reported success. Files are now syntax-checked before they are sourced.
- **Scaffolded completions, the scaffolded `test/run.sh` and the example completions no longer use the `"${x:-{}}"` default**: It appends a stray `}`, so scaffolded `run_test name '{...}'` calls were rejected by `run-tool`. `test/lint.sh` now rejects the pattern.
- **The `policy.sh` default-check warning isn't fooled by comments**: `validate` and `doctor` counted a mention of `mcp_tools_policy_check_default` in a comment as a call.
- **A malformed `notifications/cancelled` no longer ends the server**: A cancel with a missing, null or false `requestId`, or with non-object `params`, made the server exit; in minimal mode every cancel did. It is now ignored, like any notification the server can't use.
- **Closing stdin after a cancellation no longer cuts the shutdown short on bash 4+**: The server exited with status 143, dropped results still in flight and left workers running. It now delivers them and exits 0.
- **`mcp_json_quote_text ""` works on bash 3.2 under `set -u`**: It aborted with "unbound variable", so `mcp-bash doctor --json` printed invalid JSON on macOS `/bin/bash`.
- **An unsubscribe sent right after a subscribe for the same URI ends the subscription**: Requests run in parallel, so the unsubscribe could finish first, find nothing, and leave the subscription live.
- **`notifications/cancelled` cancels requests with string ids**: Only numeric ids were matched, so a cancelled call with a string id still returned its result.
- **`resources/unsubscribe` accepts the spec's `uri` param**: It removes every subscription to that URI. `subscriptionId` is still accepted. Unsubscribing something that isn't subscribed returns `{}`; a request with neither field returns `-32602` ("Resource uri required"; previously "subscriptionId required").
- **Subscription polling starts with the first `resources/subscribe`**: It used to start only with the next client message, so a client that subscribed and then waited got no updates.
- **A newline in a subscribe `name` or `uri` can no longer redirect the subscription to another resource**: Subscription records are stored as JSON.
- **The subscription poller survives an unsubscribe that arrives mid-poll**: Bash 5 stopped polling; bash 3.2 recreated the removed subscription and sent an update with an empty URI.
- **Interactive UI templates call tools correctly**: The `form`, `tree-view`, `kanban` and progress-cancel templates called `app.callTool()`, which the MCP Apps SDK does not have. They now use `app.callServerTool({ name, arguments })` and treat `isError` results as failures, and the SDK is pinned to `@modelcontextprotocol/ext-apps@2.0.3` instead of a floating version. Whether a host lets a UI call tools is still up to the host; the docs no longer blame a host bug for this.
- **`ping` is answered before `initialize`**: The MCP lifecycle allows `ping` before initialization completes; it was rejected with `-32000` and now returns `{}`.
- **Docs**: the README security table no longer says every `server.d/*.sh` file is disabled by default (only `register.sh` is; `policy.sh` is always sourced); `run-tool` examples include `--allow-self` and the flag list is complete; `mcp-bash --help` lists `run-tool --with-server-env/--source`, `validate --inspector`, `config --wrapper-env` and the main `doctor` flags; `docs/ENV_REFERENCE.md` documents `MCPBASH_HOME`, `MCPBASH_ROOTS`, the registry TTLs, the trace variables, `MCPBASH_LOG_DIR`, `MCPBASH_KEEP_LOGS`, `MCPBASH_CI_VERBOSE` and `MCPBASH_MAX_UI_RESOURCE_BYTES`; the vendoring guide links to the README's verified-install steps instead of a stale example.
- **The bash JSON quoter escapes newlines, tabs and backslashes correctly**: `mcp_json_quote_text` (used for error messages, elicitation prompts, server instructions and other strings on every bash version) wrote its escapes inside single quotes, where backslashes are literal: a newline came out as `\\n` (shown to clients as a literal `\n`), and a backslash was never matched and passed through raw, producing invalid JSON. Output now decodes to the original text.
- **Non-ASCII text is no longer corrupted in JSON under bash 3.2**: The pure-bash JSON quoter (`mcp_json_quote_text`, used for error messages, elicitation prompts and server instructions even when jq is installed) read bytes >= 0x80 as negative under bash 3.2 (the macOS `/bin/bash`) and escaped them as `\u00FFFFFFFFFFFFFFC3`, losing the rest of the character. Non-ASCII characters are now kept as-is.
- **Large payloads no longer fail or disappear**: Resource contents, prompt text and arguments, completion output, icons, embedded tool resources, SDK result payloads and bundle manifests were passed to jq as command-line arguments, which Linux caps at 128 KiB each (about 96 KiB of binary after base64) and macOS at 1 MiB in total. Above those sizes, reads and prompts failed with `-32603`, completion output was reported as invalid JSON, and embedded resources and icons were silently dropped. A `server.instructions.md` over 128 KiB stopped a Linux server from starting any child process, because the instructions were exported into the environment. These payloads now reach jq on standard input, and the instructions and icons are no longer exported. A tool result whose embedded resources cannot be attached is now an error rather than an empty result. Completion scripts still receive their metadata in environment variables (see `docs/LIMITS.md`).
- **CLI commands no longer leave state directories behind**: `run-tool`, `registry`, `config`, `validate` and `health` left a `mcpbash.state.<pid>` directory in the temp directory. A refused cleanup removal also no longer makes the server exit with status 1.
- **Embedded resources with a URI but no mime type**: A `MCP_TOOL_RESOURCES_FILE` TSV line with an empty mime column (`path<TAB><TAB>uri`) used the URI as the mime type, because tab is an IFS whitespace character.
- **URL-mode elicitation is detected again**: Client capabilities were read with a `"${1:-{}}"` default, which bash ends at the first `}` and so appends a stray `}` to a set value. The capabilities then failed to parse, the server fell back to a string match that enables form mode only, and every `mcp_elicit_url` call was declined. The same pattern affected UI extension detection (which worked by accident), `mcp_config_get`'s reading of `MCP_CONFIG_JSON`, and `mcp-bash validate`'s defaults output.
- **The `policy.sh` examples no longer turn off deny-by-default**: The README described the built-in tool policy as "default: allow all" (it denies unless allowlisted), and the README and `docs/BEST-PRACTICES.md` showed a `server.d/policy.sh` that redefined `mcp_tools_policy_check` without the built-in checks. A project copying it ran every tool regardless of `MCPBASH_TOOL_ALLOWLIST`. The built-in policy is now also available as `mcp_tools_policy_check_default`, the examples call it first, and `mcp-bash validate` and `doctor` warn when a `policy.sh` redefines the check without calling it. Existing `policy.sh` files behave as before.
- **Early `tools/call` refusals report their own code and message**: Inherit mode without `MCPBASH_TOOL_ENV_INHERIT_ALLOW`, a tool path rejected at call time, and a missing executable returned `-32603 Tool execution failed`. They now return `-32602` with the specific message (no values or paths), and `mcp-bash run-tool` prints the same messages.
- **`MCPBASH_SERVER_DIR` is honoured by `doctor`, `run-tool` and `validate`**: They assumed `server.d/` for `server.meta.json`, register files, `env.sh` and `requirements.json`. Labels in output stay relative to the project. `mcp-bash bundle` still packages the project's `server.d/` (documented in `docs/MCPB.md`).
- **SIGTERM and SIGINT stop the server promptly**: The signal traps only recorded the signal, and bash runs a trap after the pending `read` returns. A server waiting for input therefore ignored `SIGTERM` until the read timed out (up to the orphan-check interval, 30s by default), or, with a blocking read (`MCPBASH_CI_MODE` or both checks off), until the next input line. Hosts that escalate to `SIGKILL` skipped cleanup. The traps now exit at once (130/143), and the exit handler still runs.
- **Background helpers exit when the server dies**: The progress/elicitation flusher and the resource-subscription poller are background loops that relied on the server stopping them on exit. A server killed without cleanup (for example `SIGKILL`) left them running indefinitely, holding its pipes open. Each loop now exits on its next tick once the server process is gone.
- **Short read timeouts no longer shut down a connected server**: With `MCPBASH_ORPHAN_CHECK_INTERVAL` or `MCPBASH_IDLE_TIMEOUT` at 2 seconds or less, ordinary read timeouts were counted as end of input, so an idle server exited after about 6 seconds while its client was still connected. On bash 4+ a timeout (status > 128) never counts toward EOF detection; on bash 3.2 a read counts as an immediate return only if it took less than the timeout. Defaults were not affected.
- **The server exits when stdin closes, under bash 4+ with a FIFO stdin**: The timed read loop (used when the idle or orphan checks are on, the default) recognised end of input only after three quick consecutive returns. Under bash 4 and later, once a FIFO's writer closed, later reads timed out instead of reporting end of input again, so the server kept running until its idle timeout (one hour by default). A read status of 1 now ends the loop at once on bash 4+; bash 3.2 keeps the timing heuristic. Pipes and socketpairs, which Claude Desktop uses, were not affected. This was hidden in CI, which runs with `MCPBASH_CI_MODE` (blocking reads).
- **Completion scripts are no longer listed as prompts or resources**: Prompt and resource auto-discovery registered every file except `*.meta.json`, so the per-prompt completion scripts documented in 1.5.0 (`prompts/<name>/<name>.completion.sh`, or `*.completion`) appeared as extra prompts named `<name>.completion`, including in Claude Desktop's prompt menu and in bundles' static registries. Discovery now skips `*.completion.sh` and `*.completion` files; their completion lookup is unchanged.

## [1.5.0] - 2026-10-09

### Added

- **Declarative env policy in `server.d/server.meta.json`**: An optional `"env"` object can set `MCPBASH_TOOL_ENV_MODE`, `MCPBASH_TOOL_ENV_ALLOWLIST`, `MCPBASH_PROVIDER_ENV_MODE` and `MCPBASH_PROVIDER_ENV_ALLOWLIST`, so a project (including an installed MCPB bundle) can pass host-injected secrets such as an API key on to its tools and providers. The server applies it at startup, and `mcp-bash run-tool` applies it too, after any `--with-server-env`/`--source` files, which count as launch env.
  - Only those four keys are accepted. Operator opt-ins (`*_INHERIT_ALLOW`, `MCPBASH_ALLOW_PROJECT_HOOKS`, ...) and any other variable are refused with a warning that names the key, never the value.
  - Values are validated before use: modes must be valid for their key, allowlists may only name plain variables (no shell-control or reserved names such as `LD_PRELOAD`, `BASH_ENV` or `MCPBASH_*`), and values with control characters are refused. A `server.meta.json` holding more than one JSON document applies nothing. Warnings go to stderr.
  - The launch environment wins. If it sets either the mode or the allowlist for tools (or for providers), both meta values for that scope are ignored. An empty value, or an unexpanded `${user_config.*}` placeholder, counts as unset. `MCPBASH_IGNORE_META_ENV=true` ignores the section entirely.
  - `inherit` still requires the operator's `*_INHERIT_ALLOW`.
  - `mcp-bash validate` reports problems in the section, and `mcp-bash bundle` refuses a bundle whose section contains a disallowed key, because its value would ship.
- **`mcp-bash doctor` shows the tool and provider env policy**: For tools and providers it shows the effective mode and where it came from (launch env, `server.meta.json` or default), and whether each allowlisted variable is set, empty, an unexpanded placeholder or not set in the current shell. It also flags refused or invalid `server.meta.json` env keys, invalid allowlist names, and `inherit` without the operator opt-in. Values are never printed. `doctor --json` adds an `envPolicy` object and matching findings.

### Fixed

- **Refused `register.json` / `register.sh` now say why and how to fix it**: When the file, `server.d/` or the project root is group- or world-writable, a symlink, or owned by another user, the registry is refused and every tools/resources/prompts list fails. The error said only "permissions/ownership invalid". It now names the path (relative to the project, since the message can reach clients) and the fix, for example `server.d is group- or world-writable (fix: chmod g-w,o-w server.d)`. `mcp-bash doctor` checks this up front, and `mcp-bash health` explains a skipped `health-checks.sh` the same way.
- **Non-ASCII file URIs are encoded correctly on bash 3.2**: `mcp_uri_url_encode` printed bytes >= 0x80 as sign-extended values under bash 3.2 (the macOS `/bin/bash`), so `é` became `%FFFFFFFFFFFFFFC3%FFFFFFFFFFFFFFA9` instead of `%C3%A9`. Resources without an explicit `uri` whose path contains non-ASCII characters got broken `file://` URIs.
- **Per-prompt and per-resource completion scripts now time out**: Scripts found next to a prompt or resource (for example `prompts/<name>/<name>.completion.sh`) had no timeout, so a hung script held a worker on every keystroke. They now time out after `MCPBASH_COMPLETION_TIMEOUT_SECS` (default 5 seconds). These scripts are now covered by an integration test, and their file lookup and environment are documented in `docs/COMPLETION.md`.
- **Tools on Windows keep the system variables they need**: In `minimal` and `allowlist` tool env modes, tools received only `PATH`, `HOME`, `TMPDIR` and `LANG` (plus `MCP_*`/`MCPBASH_*`), while providers also kept the Windows system variables. Without `SYSTEMROOT`, Python on Windows cannot open sockets (WinError 10106). Tools now also keep `SYSTEMROOT`, `SYSTEMDRIVE`, `WINDIR`, `COMSPEC`, `PATHEXT`, `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`, `MSYSTEM` and `MSYS2_ARG_CONV_EXCL`.
- **Bundles keep their base env on platforms with an override**: Claude Desktop replaces `mcp_config.env` with a `platform_overrides.<platform>.env` rather than merging, so an override dropped `MCPBASH_PROJECT_ROOT`, `MCPBASH_TOOL_ALLOWLIST` and every `user_config` variable on that platform. The bundler now copies the base env into each override env, and `docs/MCPB.md` no longer says the env is merged. `mcp-bash bundle` also warns when override env turns on an operator opt-in such as `MCPBASH_TOOL_ENV_INHERIT_ALLOW`.
- **Bundles no longer pass unexpanded `${user_config.*}` placeholders to tools**: Claude Desktop leaves the literal placeholder text when an optional setting has no value and no default. `run-server.sh` now unsets such variables. On Windows, where the host passes TEMP but not TMP, it also sets TMP from TEMP.
- **The tool inherit-mode gate now also applies to a mode set by `server.d/policy.sh`**: `MCPBASH_TOOL_ENV_MODE=inherit` requires `MCPBASH_TOOL_ENV_INHERIT_ALLOW=true`, but the check ran before `policy.sh` was sourced, so a mode exported there skipped it. The check now runs after the policy hook. `policy.sh` is project code and can still set anything, so this guards against accidental configuration, not a hostile project.

### Changed

- **Documentation**:
  - `docs/MCPB.md` gains a "Passing secrets to tools" section and describes how Claude Desktop substitutes `user_config` values and what environment it passes.
  - `docs/BEST-PRACTICES.md` warns against splicing untrusted input into jq programs.
  - `docs/COMPLETION.md` documents per-prompt and per-resource completion scripts.
  - `README.md`, `llms.txt`, `llms-full.txt`, `docs/LLM-CONTEXT.md` and the scaffolded `server.d/README.md` are updated for the env policy, resource templates and project providers, completions, and the tool environment. The README listed the minimal tool environment as `PATH`, `HOME`, `TERM`.

### Security

- **`MCPBASH_TOOL_ENV_ALLOWLIST` names are validated with an anchored pattern**: The name check used a shell glob that only anchored the first two characters, so an entry such as `xx[$(command)]` was accepted, and reading it with indirect expansion ran the embedded command in the server's tool subshell. Names must now match `^[A-Za-z_][A-Za-z0-9_]*$` exactly; anything else is skipped. The value is set by whoever configures the server, so this was not reachable by MCP clients, but configuration data must never execute code.

## [1.4.0] - 2026-10-09

### Fixed

- **`resources/read` of a templated resource with a custom URI scheme now reaches the project provider**: Template metadata never enters the static resource registry, so reading a URI expanded from a template such as `myapi://items/{id}` found no `provider` and fell back to `file`, which returned `-32002 Resource not found`. Provider inference now maps an unrecognised scheme to `${MCPBASH_PROVIDERS_DIR}/<scheme>.sh` when that script exists. Statically discovered resources with a custom scheme and no `provider` field use the same inference. For a client-supplied URI this routing applies only to schemes the project declares, through a resource template or a static resource bound to that provider. A script in `providers/` is not reachable by naming its scheme alone. Schemes are matched case-sensitively. The scanner change also means a statically discovered `ui://` resource with no `provider` field now uses the `ui` provider, not `file` (which could not serve it).
- **File URIs no longer fail intermittently under bash 5.3**: `mcp_uri_url_encode` declared `local LC_ALL=C`. Under bash 5.3 with `LC_CTYPE=UTF-8` (the macOS Terminal default) that made calls in `$(...)` report failure about 1 time in 16, so resources without an explicit `uri` could drop out of `resources/list`. The function now runs in a subshell and sets `LC_ALL=C` there.
- **Resource providers now receive `MCPBASH_JSON_TOOL_BIN` and `MCPBASH_JSON_TOOL`**: Previously only the `ui` provider got them, so provider scripts using `${MCPBASH_JSON_TOOL_BIN:-jq}` ran with them unset. Completion providers already received both.

### Changed

- **Docs no longer claim `server.d/env.sh` runs at server startup**: `docs/PROJECT-STRUCTURE.md`, `docs/ARCHITECTURE.md` and the configuration hierarchy in `docs/BEST-PRACTICES.md` described it as applied at startup. The server has never sourced it, and neither does an MCPB bundle's `run-server.sh`; only `mcp-bash run-tool --with-server-env` does. The docs now say so and point to where a running server's environment should be set.

### Security

- **`resources/read` and `resources/subscribe` reject a `name` and `uri` that refer to different resources**: The `name` parameter (an mcp-bash extension; MCP addresses reads by `uri`) selected the provider, while the client's `uri` was passed to it unchecked. Any client could therefore send an arbitrary URI to any registered resource's provider. Such requests now fail with `-32602`. Requests with only `name`, only `uri`, or a matching pair are unaffected.
- **Provider scripts must validate their URI argument**: A provider receives any URI in its declared scheme, not only the URIs the project lists. Check `$1` and exit 3 or 4 for URIs the provider does not serve. See [docs/SECURITY.md](docs/SECURITY.md).

## [1.3.0] - 2026-04-15

### Fixed

- **Bundle prompts now include `text` field per MCPB v0.3 schema**: The bundler reads the template `.txt` file for each prompt and embeds its content as the required `text` field in the manifest's `prompts` array. Prompts without a resolvable template file are excluded from the manifest to maintain schema compliance. Previously, prompts only had `name`, `description`, and `arguments`, which failed strict v0.3 validation.
- **Bundle prompt scan now finds scaffolded prompt layouts**: The glob pattern now matches `prompts/<name>/<name>.meta.json` (created by `mcp-bash scaffold prompt`) in addition to the flat and `prompt.meta.json` nested layouts.

### Added

- **Semver validation warning for bundle version**: `mcp-bash bundle --validate` now warns when the resolved version string is not valid semver (MAJOR.MINOR.PATCH). The upstream MCPB CLI is adding strict semver rejection; this warning gives early feedback. Non-semver versions still produce bundles but may be rejected by future MCPB tooling.

### Changed

- **MCPB documentation updated for upstream spec changes**: `docs/MCPB.md` now documents the `text` field in prompt manifest entries, manifest v0.4 awareness (UV runtime), clarifies that `platform_overrides.env` merges with (not replaces) base env, and notes the potential `@anthropic-ai/mcpb` package rename.

## [1.2.2] - 2026-04-05

### Fixed

- **Bundle icon/screenshot path resolution now works on macOS**: The v1.2.1 fix for resolving `server.d/`-relative paths used `realpath -m` (GNU coreutils), which macOS's BSD `realpath` doesn't support. Replaced with a portable shell-based resolution using `cd` + `pwd`. Also normalizes the destination path in the bundle to avoid `../` escaping the bundle directory.
- **Installer warns when another mcp-bash shadows the new install**: After installation, the installer checks if a different `mcp-bash` binary earlier in `PATH` would take precedence over the one just installed (e.g., a stale manual install shadowing a Homebrew install). Prints version and path of the shadowing binary.

## [1.2.1] - 2026-04-04

### Fixed

- **Installer no longer blocks when `MCPBASH_HOME` points to a different path**: Previously, the installer refused to run whenever `MCPBASH_HOME` was set, even if it pointed to a vendored runtime (`.mcp-bash/`) rather than the install target. The check now only blocks when `MCPBASH_HOME` matches the install directory, allowing CI workflows to install the full CLI alongside a vendored runtime.
- **Vendored runtime gives a clear error for CLI commands**: Running CLI commands (e.g., `validate`, `bundle`, `doctor`) against a vendored or embedded runtime previously failed with a cryptic "No such file or directory". The entrypoint now detects missing CLI modules and prints a helpful message explaining that a full mcp-bash install is required.
- **Vendor docs now clarify CLI commands are not included**: `docs/VENDORING.md` explicitly lists which commands require a full install and notes that the installer won't conflict with a vendored copy.
- **Bundle resolves `icons` and `screenshots` paths from both project root and `server.d/`**: Paths in the `server.meta.json` `icons` and `screenshots` arrays can now be relative to either the project root (`assets/icons/foo.png`) or to `server.d/` (`../assets/icons/foo.png`). Previously, only project-root-relative paths worked, so `../` paths from `server.d/` would fail with a spurious warning.

## [1.2.0] - 2026-04-03

### Added

- **`mcp-bash vendor` command**: Embeds the mcp-bash runtime into a project's `.mcp-bash/` directory for committing to git, eliminating the need for a system-wide install at runtime. Useful for dev teams, CI pipelines, and MCP clients that do not support MCPB bundles. Includes `--verify` for SHA-256 integrity checking, `--upgrade` to update in place, and `--dry-run` to preview. Writes a `vendor.json` lockfile recording version, digest, source, and timestamp. See [docs/VENDORING.md](docs/VENDORING.md).
- **Homebrew tap**: mcp-bash is now installable via `brew install yaniv-golan/mcp-bash/mcp-bash`. Homebrew handles upgrades (`brew upgrade mcp-bash`) and is the recommended install method on macOS and Linux. The formula is auto-bumped on each release.
- **Renovate preset for vendored copies**: A `renovate-preset.json` in this repo configures Renovate to track `vendor.json` against GitHub Releases and open automatic upgrade PRs. Users opt in with `{"extends": ["github>yaniv-golan/mcp-bash-framework//renovate-preset"]}` in their `renovate.json`.

### Fixed

- **Built-in resource providers now embedded in bundles and vendor trees**: Both `lib/resources.sh` and `sdk/tool-sdk.sh` resolve built-in providers (`file://`, `https://`, `git://`, `echo://`, `ui://`) via `${MCPBASH_HOME}/providers/`. Previously, `mcp-bash bundle` did not copy the framework's `providers/` directory into `.mcp-bash/`, so any server using built-in resource providers would silently fail in bundled deployments unless the project overrode every provider. The `providers/*.sh` files are now always included in the embedded framework tree.

### Changed

- **Shared embed logic extracted to `lib/cli/embed.sh`**: The framework embedding logic previously duplicated between `bundle` and the new `vendor` command is now in a single shared module (`EMBED_REQUIRED_LIBS`, `mcp_embed_framework()`, `mcp_embed_compute_hash()`). `bundle.sh` delegates to it unchanged.

## [1.1.5] - 2026-04-03

### Added

- **Static `tools` array in MCPB manifest**: The bundler now scans `tools/*/tool.meta.json` at bundle time and emits a `tools` array of `{name, description}` objects in `manifest.json`. This enables pre-install discovery in extension stores — clients can show what an extension offers before downloading. Emitted alongside the existing `tools_generated` flag.
- **Static `prompts` array in MCPB manifest**: Same pattern for prompts — scans `prompts/*.meta.json` and `prompts/*/prompt.meta.json`, extracts `name`, `description`, and `arguments` (property names from the JSON schema). Emitted alongside `prompts_generated`.
- **`icons` array passthrough in MCPB manifest**: When `server.meta.json` defines an `icons` array (with `{src, size, theme}` objects for light/dark and multi-size variants), the bundler passes it through to `manifest.json` and copies referenced local files into the bundle. Supports the MCPB spec's themed icon feature for proper dark mode rendering in extension stores.
- **`screenshots` passthrough in MCPB manifest**: When `server.meta.json` defines a `screenshots` array, the bundler passes it through and copies referenced local files into the bundle for extension store listings.
- **`platform_overrides` passthrough in MCPB manifest**: When `server.meta.json` defines `platform_overrides`, the bundler merges it into `server.mcp_config.platform_overrides` in the manifest. Enables per-platform command, args, and env overrides for cross-platform bundles (e.g., `.exe` suffix on Windows, `DYLD_LIBRARY_PATH` on macOS).
- **`_meta` passthrough in MCPB manifest**: When `server.meta.json` defines `_meta`, the bundler passes it through as a top-level manifest field. Supports platform-specific client integration metadata (e.g., Windows Store `package_family_name`, static `initialize`/`tools/list` responses).
- **`localization` passthrough in MCPB manifest**: When `server.meta.json` defines `localization` (with `resources` path template and `default_locale`), the bundler passes it through for i18n of user-facing fields.

### Fixed

- **Registry cache epoch-boundary race**: `load_cache_if_empty` in tools, resources, resource templates, and prompts called `date +%s` independently of the caller's `now` timestamp. When the epoch second rolled over between the two calls, `LAST_SCAN` could exceed `now`, producing a negative cache age that satisfied any TTL check — skipping the disk scan entirely. Each function now accepts the caller's `now` to ensure `LAST_SCAN <= now`.

## [1.1.4] - 2026-04-02

### Fixed

- **`mcp-bash config` now includes `MCPBASH_TOOL_ALLOWLIST` in all output modes**: All six output modes (`--json`, `--client claude-desktop`, `--client cursor`, `--client claude-cli`, `--client windsurf`, `--client librechat`, `--wrapper`/`--wrapper-env`, `--inspector`) now emit `MCPBASH_TOOL_ALLOWLIST="*"` in the generated env block. Previously, the allowlist was omitted, causing all tools to be silently blocked by the default-deny policy when users copied config output verbatim.

### Added

- **Per-Client Snippets in README include `MCPBASH_TOOL_ALLOWLIST`**: All six client setup snippets (Claude Desktop, Claude CLI, LibreChat, OpenAI Agents SDK, Clawdbot, Highlight AI) now show `MCPBASH_TOOL_ALLOWLIST="*"` with a security note directing users to narrow it for production.
- **Agent Quick Start section in `llms.txt` and `llms-full.txt`**: A new "Quick Start for AI Agents Building MCP Servers" section provides step-by-step build instructions, highlights the critical allowlist requirement, and documents CLI wrapper patterns (PATH resolution via `mcp_detect_cli`, `set -uo pipefail` error handling).
- **New example `examples/15-cli-wrapper`**: Demonstrates the most common real-world MCP server pattern — wrapping an external CLI with `mcp_detect_cli` for PATH resolution, `set -uo pipefail` for error capture, and SDK helpers for MCP-compliant output.
- **`set -e` + CLI wrapper pitfall documented in `docs/BEST-PRACTICES.md` §4.5**: Documents that `set -euo pipefail` makes error branches unreachable when wrapping CLIs that return non-zero for business errors, with a fix example.

## [1.1.3] - 2026-03-02

### Fixed

- **Resource annotations now preserved in `resources/list`**: Regular resources discovered via `*.meta.json`, inline `# mcp:` headers, or manual registration (`register.sh`) now expose optional `annotations` (e.g., `audience`, `priority`) through `resources/list`. Previously, annotations were only surfaced for resource templates; they were silently dropped for regular resources.

## [1.1.2] - 2026-03-02

### Fixed

- **Initialize instructions now surfaced to clients**: Added support for `initialize.result.instructions` sourced from `server.d/server.instructions.md`. Instructions are emitted for negotiated protocol versions `2025-03-26` and newer, and omitted for `2024-11-05` for spec-accurate downgrade behavior.

## [1.1.1] - 2026-02-03

### Changed

- **`MCPBASH_LOG_LEVEL` boolean normalization**: Boolean-like values are now normalized to RFC-5424 levels: `true`/`1` → `debug`, `false`/`0` → `info`. This supports UI toggles (like Claude Desktop Extensions settings) that map boolean debug settings to `MCPBASH_LOG_LEVEL`. The normalized value is re-exported so tool subprocesses inherit canonical level names. **Breaking:** Existing deployments setting `MCPBASH_LOG_LEVEL=true` (intending "enable logging") will now get debug-level verbosity instead of info-level.

## [1.1.0] - 2026-01-30

### Added

- **MCP Apps extension support (SEP-1865)**: Full implementation of the MCP Apps specification for serving interactive HTML UIs. Tools can now provide rich visual interfaces via `ui://` resources. Includes auto-discovery of UI resources, CSP header generation, and template-based UI generation.

- **Auto-inference of `_meta.ui.resourceUri`**: When a tool has a `ui/` subdirectory containing `index.html` or `ui.meta.json`, the framework automatically links the tool to its UI resource. No manual `_meta.ui` configuration needed—the URI is generated as `ui://{server-name}/{tool-name}`.

- **`mcp-bash scaffold ui` command**: New scaffold command for creating UI resources:
  - `mcp-bash scaffold ui <name>` — creates standalone UI in `ui/<name>/`
  - `mcp-bash scaffold ui --tool <name>` — creates UI for existing tool (auto-linked)
  - Generates `index.html` with MCP Apps SDK integration, `ui.meta.json` with CSP configuration

- **`--ui` flag for `mcp-bash scaffold tool`**: Create a tool with UI in one command: `mcp-bash scaffold tool weather --ui`. Generates both the tool files and the `ui/` subdirectory with working templates.

- **UI Resources Guide**: New documentation at `docs/guides/ui-resources.md` covering static HTML UIs, template-based UIs, auto-linking, CSP configuration, and the MCP Apps SDK.

- **Pre-push hook**: New `.githooks/pre-push` runs unit tests and bundle validation before pushing, catching issues locally before CI.

- **Bash 3.2 lint check**: `test/lint.sh` now sources core libs with `/bin/bash` to catch bash 4+ features (like `declare -gA`) before CI fails on macOS.

### Fixed

- **`MCPBASH_HOME` override support**: The `bin/mcp-bash` script now respects the `MCPBASH_HOME` environment variable, allowing the installed binary to use development code during testing.

### Documentation

- Added MCP Apps concepts documentation (`docs/concepts/mcp-apps.md`)
- Added UI SDK reference (`docs/reference/ui-sdk.md`)
- Added UI templates reference (`docs/reference/ui-templates.md`)
- Added known limitations section for Claude Desktop MCP Apps support
- Updated `docs/PROJECT-STRUCTURE.md` to document the `ui/` directory
- Updated scaffold READMEs with UI documentation links
- Added MCP Apps to README feature list and spec compliance table

## [1.0.0] - 2026-01-26

**mcp-bash reaches 1.0.0** — the framework is now considered stable for production use. The protocol implementation is complete, the SDK API is mature, and the project has been validated across multiple MCP servers and clients.

### Added

- **Clawdbot client documentation**: Added configuration instructions for [Clawdbot](https://github.com/clawdbot/clawdbot), which uses [mcporter](https://github.com/steipete/mcporter) for MCP integration. Config goes in `~/.mcporter/mcporter.json`.
- **Highlight AI client documentation**: Added configuration instructions for [Highlight AI](https://highlightai.com). Tested end-to-end. Uses UI-based config: Settings → Connections → Add → Custom command.

### Changed

- **Version bump to 1.0.0**: Signals API stability. The MCP protocol implementation covers the full 2025-11-25 spec (tools, resources, prompts, elicitation, roots, progress, cancellation). No breaking changes are expected in the 1.x series.

## [0.14.0] - 2026-01-24

### Added

- **Zombie process mitigation**: MCP servers now include automatic defenses against zombie/orphan process accumulation. **Idle timeout** (default: 1 hour) exits the server when no client activity is received. **Orphan detection** (Unix only) exits the server when the parent process dies. Both features are enabled by default and can be configured via environment variables (`MCPBASH_IDLE_TIMEOUT`, `MCPBASH_IDLE_TIMEOUT_ENABLED`, `MCPBASH_ORPHAN_CHECK_ENABLED`, `MCPBASH_ORPHAN_CHECK_INTERVAL`). See [DEBUGGING.md](docs/DEBUGGING.md#zombieorphaned-mcp-server-processes) for details.

### Fixed

- **Registry generation missing `progressExtendsTimeout` and `maxTimeoutSecs` fields**: Tools with progress-aware timeout configuration in `tool.meta.json` would silently fall back to fixed countdown mode because the registry generator did not copy `progressExtendsTimeout` or `maxTimeoutSecs` fields to `.registry/tools.json`. The timeout watchdog reads these values from the registry at runtime, but they were always null, causing `MCPBASH_PROGRESS_EXTENDS_TIMEOUT` to never be set. Fix: added both fields to auto-discovery and manual registration registry generation paths. Added unit tests to prevent regression.

- **`.debug` file detection not enabling MCP debug logs**: The `server.d/.debug` marker file correctly set `MCPBASH_LOG_LEVEL=debug`, but debug-level MCP log notifications were still filtered out. Root cause: `MCP_LOG_LEVEL_CURRENT` was initialized when `logging.sh` was sourced (before `.debug` file detection runs). Fix: sync MCP logging level after `mcp_runtime_init_paths()` in `mcp_core_bootstrap_state()`.

- **Zombie mitigations causing CI test failures**: The zombie process mitigation feature's timeout-based read loop caused widespread test failures in CI. The new read loop with `read -t` behaves differently than the simple blocking `read` when processing piped input. Fix: disable both idle timeout and orphan detection when `MCPBASH_CI_MODE=true` to restore simple blocking read loop behavior.

- **Log notification corruption in handler responses**: Log notifications emitted inside command substitutions (e.g., during registry building) could intermittently corrupt JSON-RPC responses due to unreliable fd inheritance in nested bash subshells. Fix: defer log notifications to a queue file during handler execution and flush after the handler completes. This ensures notifications are emitted outside any command substitution context. Trade-off: log notifications are now batched per-request rather than streaming in real-time. Progress notifications (used for timeout extension) are unaffected as they use a separate file-based mechanism.

## [0.13.0] - 2026-01-22

### Added

- **`timeoutHint` field in `tool.meta.json`**: New optional field that provides actionable guidance appended to timeout error messages. When a tool times out, the hint text is displayed as a "Suggestion:" in the error message and is also available programmatically via `structuredContent.error.hint`. This helps LLMs adjust their approach (e.g., use smaller batches, enable dry-run mode). Example: `"timeoutHint": "Use dryRun=true first. For large datasets, try limit <= 100."`. See [Timeout Strategy Guide](docs/BEST-PRACTICES.md#timeout-strategy-guide) for details.

### Documentation

- **Runtime CLI detection pattern**: New section in BEST-PRACTICES.md documenting how to detect external CLIs when MCP hosts spawn servers with restricted PATH (missing version manager shims). Includes `mcp_detect_cli()` helper covering pyenv, asdf, mise, nvm, fnm, volta, rbenv, goenv, cargo, and Homebrew paths. Clarifies that `server.d/env.sh` is not auto-sourced at server startup.

### Changed

- **Progress-aware timeout now extends on any pattern match**: When using `mcp_run_with_progress`, the timeout watchdog now extends on any pattern match, not just lines with a `.progress` field. This decouples activity detection ("I'm alive") from progress reporting ("I'm X% done"). Tools emitting structured events like `{"type":"step_start"}` that match the progress pattern will now survive past their nominal timeout even without a `.progress` field. Debug logging added when activity is detected without progress extraction. See [BEST-PRACTICES.md §4.9](docs/BEST-PRACTICES.md) for details.

## [0.12.0] - 2026-01-21

### Changed

- **Timeout errors now use `isError: true` format** instead of JSON-RPC `-32603` errors. This improves LLM feedback by ensuring clients display the full timeout message and providing structured metadata (`type`, `reason`, `timeoutSecs`, `exitCode`) for programmatic handling. Cancellation (`-32001`) remains a protocol error. See [Timeout Strategy Guide](docs/BEST-PRACTICES.md#timeout-strategy-guide) for details.

## [0.11.0] - 2026-01-19

### Added
- **`--array-path` parameter for `mcp_json_truncate`**: New optional parameter to specify which array to truncate in JSON responses. Allows tool authors to declare their data structure (e.g., `--array-path ".data"`, `--array-path ".hits.items"`) instead of relying on hardcoded heuristics. Returns structured errors (`path_not_found`, `invalid_array_path`, `invalid_path_syntax`) for invalid paths. Path syntax is validated before jq interpolation for security. Backward compatible: without `--array-path`, falls back to top-level arrays and `.results` heuristic. See BEST-PRACTICES.md "Truncating large results" section.

## [0.10.0] - 2026-01-18

### Added
- **`mcp_config_load` / `mcp_config_get` SDK helpers**: Unified configuration loading with standard precedence (env var → file → example → defaults). `mcp_config_load` accepts `--env`, `--file`, `--example`, and `--defaults` flags; performs shallow merge with jq (last-source-wins without jq). `mcp_config_get` extracts values by jq path with optional `--default`. Supports minimal mode (top-level keys only without jq). See BEST-PRACTICES.md "Configuration loading" section.
- **`user_config` bundle support**: Bundles can now declare user-configurable options via `MCPB_USER_CONFIG_FILE`, `MCPB_USER_CONFIG_ENV_MAP`, and `MCPB_USER_CONFIG_ARGS_MAP` in `mcpb.conf`, or via `user_config`, `user_config_env_map`, and `user_config_args_map` in `server.d/server.meta.json`. User config fields are validated for schema correctness (type, title required; type-specific properties like `sensitive`, `min`/`max`, `multiple`). Env and args mappings are validated to reference existing config keys. Generated manifests include `user_config` section and proper `${user_config.KEY}` variable substitution in `mcp_config.env` and `mcp_config.args`. See docs/MCPB.md "User Configuration" section.
- **Additional MCPB manifest fields**: Bundle manifests now support optional metadata fields for registry/marketplace listing: `MCPB_LICENSE` (SPDX identifier), `MCPB_KEYWORDS` (space-separated), `MCPB_HOMEPAGE`, `MCPB_DOCUMENTATION`, `MCPB_SUPPORT`, `MCPB_PRIVACY_POLICIES` (space-separated URLs). Also added compatibility constraints: `MCPB_COMPAT_CLAUDE_DESKTOP` (semver), `MCPB_RUNTIME_PYTHON`, `MCPB_RUNTIME_NODE`. All fields are optional and omitted from manifest when not set.
- **`mcp_error` SDK helper**: Convenience wrapper for tool execution errors with consistent schema. Takes `<type> <message>` with optional `--hint` and `--data` flags. Builds normalized error JSON and delegates to `mcp_result_error`. Logs at debug level for all errors; logs at warn level when hint provided. See BEST-PRACTICES.md "Convenience error helper" section and ERRORS.md "SDK Support" section.
- **`mcp_download_safe` SDK helper**: New function for SSRF-safe HTTPS downloads in tools. Wraps the HTTPS provider with ergonomic API: named flags (`--url`, `--out`, `--allow`), automatic retries with exponential backoff, structured JSON responses (`{"success":true,"bytes":N,"path":"..."}` or `{"success":false,"error":{...}}`), and `set -e` safe (always returns 0). See BEST-PRACTICES.md "Secure downloads" section.
- **`mcp_download_safe_or_fail` SDK helper**: Fail-fast wrapper for `mcp_download_safe` that returns the output path on success or fails the tool with `-32602` on error. Simplifies common "download or die" pattern: `path=$(mcp_download_safe_or_fail --url "$url" --out "$tmp" --allow "example.com")`.
- **`mcp_result_text_with_resource` SDK helper**: Convenience wrapper for tool responses with embedded resources. Combines `mcp_result_success` with resource embedding via `--path`, `--mime`, `--uri` flags. Supports multiple resources. MIME type auto-detected if omitted (requires `file` command). See BEST-PRACTICES.md "Embedding resources in tool responses" section.
- **Redirect detection in HTTPS provider**: URLs that return 3xx redirects now produce a `redirect` error type with the target location in `.error.location`. This helps users identify canonical URLs without silently failing. Redirects are not retried (deterministic behavior).
- **`MCPBASH_HTTPS_USER_AGENT` env var**: Custom User-Agent for HTTPS provider requests. The `mcp_download_safe` SDK helper sets `mcpbash/<version> (tool-sdk)` by default; override via `--user-agent` flag or this env var.

### Fixed
- **Tool arguments corrupted when containing escaped quotes**: Fixed a bug where tool arguments containing escaped quotes (e.g., `Status in ["New", "Intro"]`) would fail to parse with "Command is required" errors. The root cause was jq's `@tsv` filter double-escaping backslashes, turning valid `\"` into invalid `\\"`. Replaced single `@tsv` extraction with separate jq calls. Added JSON validation before tool execution to catch corruption early with clear error messages. 
- **gojq compatibility in debug redaction**: Replaced `keys_unsorted` with `keys` in `mcp_io_debug_redact_payload()`. The `keys_unsorted` function is jq-specific and not available in gojq, causing debug redaction to fail silently when gojq was the JSON tool.
- **Incomplete JSON escaping in minimal mode**: `mcp_json_escape_string()` fallback (used when jq/gojq unavailable) now properly escapes all control characters including `\b` (backspace), `\f` (form feed), and other 0x00-0x1F characters via `\u00XX` encoding. Previously only escaped `\n`, `\r`, `\t`, `\\`, and `\"`, which could produce invalid JSON.
- **Potential secret leakage in debug payload redaction**: When jq is unavailable, `mcp_io_debug_redact_payload()` now emits a secure fingerprint (`[payload hash=... bytes=...]`) instead of attempting fragile regex-based redaction. The previous sed fallback could leak partial secrets when values contained escaped quotes (e.g., `"pass\"word"`). Follows fail-closed security: if we can't redact correctly, we redact everything.
- **Log injection in resources debug log**: Resource names and URIs are now sanitized before writing to `resources.debug.log`, escaping newlines and carriage returns to prevent injection of fake log entries via malicious resource names.

### Documentation
- **Minimal mode limitations**: Documented known limitations in `docs/MINIMAL-MODE.md` including unicode escape sequences (`\uXXXX`) not being decoded (passed through as literals) and debug payload logging emitting fingerprints instead of full content.
- **MCPB code signing**: Added optional code signing workflow to `docs/MCPB.md` using the official MCPB CLI (`@anthropic-ai/mcpb`) for production distribution. Documents `mcpb sign`, `mcpb verify`, and related commands.

## [0.9.13] - 2026-01-13

### Added
- **Bundle libs sync test**: New CI test (`test/unit/bundle_libs_sync.bats`) that verifies `BUNDLE_REQUIRED_LIBS` includes all libraries sourced by `bin/mcp-bash`. Prevents broken releases with missing bundled libraries (e.g., 0.9.9, 0.9.10).

### Fixed
- **errexit (set -e) state leak in functions**: Fixed a bug where `mcp_with_retry` and several internal functions would modify the caller's errexit shell state. Functions using `set +e; cmd; rc=$?; set -e` patterns would leave errexit enabled even if the caller had it disabled, causing unexpected script termination. Replaced with errexit-safe `cmd && rc=0 || rc=$?` pattern. Affected functions: `mcp_with_retry` (SDK), `mcp_tools_validate_output_schema`, `mcp_tools_call`, `mcp_registry_register_execute`, `mcp_cli_health`.

## [0.9.12] - 2026-01-13

### Added
- **`mcp_extract_cli_error` SDK helper**: New function to extract error messages from CLI tools that output structured JSON errors to stdout (common with `--json` flags) instead of stderr. Checks common patterns (`.error.message`, `.error` string, `.message` with status flags, `.errors[0].message`) before falling back to stderr. Improves LLM self-correction by providing meaningful error messages instead of empty strings. See BEST-PRACTICES.md §4.4 "Handling CLIs with structured JSON errors".

### Fixed
- **Incorrect JSON-RPC error code for tool errors**: Changed "Tool path unavailable" and "Tool executable missing" errors from `-32601` (Method not found) to `-32602` (Invalid params) per JSON-RPC 2.0 and MCP specifications. The `-32601` code is reserved for when the RPC method itself doesn't exist; tool-related errors are parameter validation failures and should use `-32602`. This aligns with the existing "Tool not found" error which correctly uses `-32602`.

## [0.9.11] - 2026-01-12

### Added
- **`--stderr-file` option for `mcp_run_with_progress`**: New option to capture non-progress stderr lines to a file while still forwarding progress notifications to MCP. Enables MCP tools to report detailed CLI error messages when using progress forwarding. See BEST-PRACTICES.md §4.9 "Capturing non-progress stderr".

### Documentation
- **SECURITY.md**: Added production deployment checklist, critical `policy.sh` security warning, known security limitations section (rate limiting, TOCTOU, input validation, debug logging, env inheritance), and gateway requirements for remote access.

## [0.9.10] - 2026-01-08

### Fixed
- **Bundle missing progress-passthrough.sh**: Added `progress-passthrough` to `BUNDLE_REQUIRED_LIBS` in bundle.sh. This library is sourced by `sdk/tool-sdk.sh` for `mcp_run_with_progress` functionality and was missing from bundles.

## [0.9.9] - 2026-01-08

### Fixed
- **Bundle missing handler_helpers.sh**: Added `handler_helpers` to `BUNDLE_REQUIRED_LIBS` in bundle.sh. This library is sourced by `core.sh` and was missing from bundles, causing runtime failures.

## [0.9.8] - 2026-01-08

### Changed
- **CI/CD improvements**: Bundle validation is now part of release gates via new `bundle-sanity` job that validates `mcp-bash bundle --help` and `mcp-bash bundle --validate` on every push. Prevents broken bundle functionality from reaching releases when non-bundle-path changes break bundle code. Full bundle creation tests remain in separate `bundle.yml` workflow for thorough path-triggered testing.
- **Consistent Windows CI policy**: `bundle.yml` now uses `continue-on-error` for Windows matrix jobs, matching the main CI workflow policy. Windows failures are reported but don't block the workflow.
- **CI workflow cleanup**: Removed unreachable Windows-specific code from Ubuntu-only jobs (`lint`, `unit`, `stress`). These jobs never run on Windows, so the conditional Windows path setup was dead code.

### Fixed
- **Bundle corrupted resources.json for parameterized resources**: `mcp_resources_scan()` now correctly skips resources with `uriTemplate` field. Previously, resources defining a `uriTemplate` (for parameterized access like `file:///{path}`) would get incorrectly added to `resources.json` with a fabricated `file://` URI based on the meta.json path, corrupting the registry. These resources now only appear in `resource-templates.json` as intended per MCP spec.

## [0.9.7] - 2026-01-08

### Changed
- **Internal refactoring**: Minor internal improvements and bug fixes from v0.9.6.

## [0.9.6] - 2026-01-08

### Added
- **`mcp_require` helper**: New function for conditional library sourcing with duplicate-load prevention. Simplifies optional dependency loading in tools and SDK code. See `lib/require.sh`.

### Changed
- **Release workflow**: Release job now runs as part of CI workflow with `needs:` dependency on core test jobs. Releases are created after lint, unit, integration (Ubuntu + macOS), and compatibility tests pass. Windows integration tests run in parallel but do not block releases (failures are reported as warnings with artifacts). Previously, all three OS integration tests were required, causing Windows slowness to delay releases.
- **Internal refactoring**: Consolidated error response formatting in handlers and standardized error variable naming to `_ERROR_CODE`/`_ERROR_MESSAGE` for consistency across the codebase.

### Fixed
- **Malformed JSON in notifications/message**: Fixed edge case where `mcp_logging_emit()` could emit malformed JSON (`"logger":,"data":}`) when the internal quote function failed silently. Added defensive validation to ensure quoted strings are never empty.
- **Validator missing uriTemplate support**: `mcp-bash validate` now accepts `uriTemplate` as a valid alternative to `uri` for resource templates, per MCP spec. Previously, resources with only `uriTemplate` (no `uri`) failed validation with "missing required uri". The validator now:
  - Accepts either `uri` OR `uriTemplate` (not both required)
  - Warns when both are present (mutually exclusive per spec)
  - Validates that `uriTemplate` contains `{variable}` placeholders

## [0.9.5] - 2025-01-08

### Added
- **Debug file detection**: Create `server.d/.debug` to enable `MCPBASH_LOG_LEVEL=debug` persistently per-project. Eliminates boilerplate debug detection in `server.d/env.sh`. Environment variable takes precedence if set. See [DEBUGGING.md](docs/DEBUGGING.md#debug-file-persistent-debug-mode).
- **Progress-aware timeout extension**: Long-running tools that emit progress can now extend their timeout dynamically instead of being killed after a fixed duration. Opt-in via `MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true` (global) or `"progressExtendsTimeout": true` in `tool.meta.json` (per-tool). The watchdog resets its idle timer on each progress emission, with a hard cap via `MCPBASH_MAX_TIMEOUT_SECS` (default 600s) to prevent runaway processes. Three timeout variants are now distinguished in error messages: fixed timeout, idle timeout (no progress for N seconds), and max exceeded (hard cap reached). When a tool emits progress but times out with the feature disabled, a warning is logged suggesting enablement. See [BEST-PRACTICES.md](docs/BEST-PRACTICES.md) §4.3 and [ENV_REFERENCE.md](docs/ENV_REFERENCE.md).
- **Debug EXIT trap**: New `MCPBASH_DEBUG=true` enables an EXIT trap that logs exit location and call stack on non-zero exits, helping diagnose `set -e` failures. Use `MCPBASH_DEBUG_ALL_EXITS=true` to log all exits (not just failures). Installed automatically in `lib/timeout.sh` when sourced.
- **Integration test debug mode**: New `MCPBASH_INTEGRATION_DEBUG_FAILED=true` re-runs failed integration tests with `bash -x` tracing and outputs the last 50 lines of trace for easier debugging.
- **Custom lint check**: `test/lint.sh` now warns about the dangerous `local var; var=$(cmd)` pattern that causes `set -e` to exit on command failure. The safe pattern is `local var=$(cmd)` which masks the exit code via the `local` builtin.

### Changed

### Fixed
- **set -e exit in with_timeout**: Fixed a bug where `with_timeout` would exit prematurely when grep found no timeout marker in the watchdog state file. The pattern `local var; var=$(grep ...)` causes `set -e` to exit on grep's non-zero return code (no match). Fixed by combining declaration and assignment (`local var=$(grep ...)`), which masks the exit code via the `local` builtin.

## [0.9.4] - 2026-01-07

### Added
- **Static registry mode** (`MCPBASH_STATIC_REGISTRY=1`): Opt-in mode for bundle deployments that skips runtime discovery and uses pre-generated `.registry/*.json` cache files directly. Reduces cold start time by skipping TTL checks, fastpath detection, and directory scanning. When enabled:
  - Loads pre-generated cache immediately without freshness checks
  - Skips `register.sh` execution (shell code) but still honors `register.json` (data-only declarative overrides)
  - Falls back to normal discovery if cache is missing/invalid
  - Respects CLI forced refresh (`mcp-bash registry refresh` still works)
  - Logs info message on first request to alert developers if static mode is accidentally left enabled
  - Cache format versioning (`format_version: 1`) for future compatibility
- **MCPB_STATIC bundle config**: Bundles now use static registry mode by default for zero-config fast cold start. The bundler automatically:
  - Runs `registry refresh` to pre-generate `.registry/*.json` files
  - Adds `.registry` to `MCPB_INCLUDE` if not present
  - Sets `MCPBASH_STATIC_REGISTRY=1` in bundle manifest environment
  - To opt out, set `MCPB_STATIC=false` in `mcpb.conf` (accepts `false`, `0`, `no`, `off`)
- **LLM context documentation**: New `docs/LLM-CONTEXT.md` guide covering patterns for building MCP servers that LLM agents can use effectively. Includes writing effective tool descriptions, parameter documentation, including examples in metadata, documenting tool relationships, creating domain model resources, discovery tool patterns, client compatibility workarounds for custom URI schemes, and anti-patterns to avoid. Includes documentation quality checklist.
- **BEST-PRACTICES.md §4.2 "LLM-friendly tool metadata"**: Quick reference for rich descriptions, parameter docs, and domain resources with cross-reference to full LLM-CONTEXT.md guide.
- **docs/README.md**: Added LLM context patterns entry to documentation index.

### Changed
- **Scaffold template improvements**: `scaffold/tool/tool.meta.json` now generates description placeholders with "When to use", "Not for", and "Examples" sections to encourage LLM-friendly documentation from the start. Parameter descriptions include format examples.
- **BEST-PRACTICES.md section renumbering**: Sections §4.3-§4.9 renumbered to accommodate new §4.2.

### Fixed
- **Tool error code propagation**: Fixed bug where early-exit tool errors (e.g., "tool not found", "path unavailable") returned generic `-32603 "Tool execution failed"` instead of specific error codes (`-32602`, `-32601`). The `mcp_tools_error()` function now properly sets `_MCP_TOOLS_RESULT` so handlers receive the specific error code and message. Policy hook errors now surface correctly with their original error codes and data payloads.
- **`mcp_result_success` default max_text_bytes increased to 100KB**: Changed default from 4096 to 102400 bytes. The previous 4KB limit caused LLMs to see unhelpful summaries like "Success: object with 3 keys" instead of actual data when tools returned moderately-sized JSON. New default ensures typical LLM responses are included in full. Configurable via `MCPBASH_MAX_TEXT_BYTES` environment variable for edge cases (e.g., constrained environments or explicit summarization).
- **Multi-line descriptions in resource metadata**: Fixed `lib/resources.sh` registry parsing to handle multi-line descriptions in `resource.meta.json`. Previously, descriptions with embedded newlines would break the field array parsing, causing resources to silently fall back to default names and empty descriptions. Now uses individual jq calls per field (matching the pattern already used in `lib/tools.sh`).
- **Registry cache loading not setting LAST_SCAN**: Fixed `lib/tools.sh`, `lib/resources.sh`, and `lib/prompts.sh` to set `*_LAST_SCAN` to current time after successfully loading registry cache from disk. Previously, loading a valid cache file would leave `*_LAST_SCAN` uninitialized, causing the TTL check to always fail and trigger unnecessary full directory scans on the first request. This caused timeouts in Claude Desktop when `tools/list` took too long. The fix trusts pre-generated caches and starts the TTL window from now (not file mtime, which would fail for freshly extracted bundles). Uses empty string as the "uninitialized" state to distinguish from explicit `LAST_SCAN=0` (used by CLI commands to force a scan).

## [0.9.3] - 2025-01-06

### Added
- **`mcp_run_with_progress` SDK helper**: Forward subprocess progress to MCP notifications. Wraps external CLIs and parses their stderr (or a dedicated progress file) to emit progress events. Supports three extraction modes: `json` (NDJSON output), `match1` (percentage patterns like `50%`), and `ratio` (counter patterns like `[5/10]`). Includes `--progress-file` option for ffmpeg-style CLIs that write progress to dedicated files. See BEST-PRACTICES.md §4.8 for common patterns and usage examples.
- **MCPB_INCLUDE config option**: New `mcpb.conf` setting to include custom directories in bundles beyond the defaults (tools, resources, prompts, completions, server.d, lib, providers). Supports nested paths like `config/schemas`. Rejects path traversal (`..`) and absolute paths for security. Warns on missing directories.
- **run-tool environment sourcing**: New options for sourcing environment files before tool execution:
  - `--with-server-env`: Sources `server.d/env.sh` before running the tool, matching server runtime behavior
  - `--source FILE`: Sources any env file before execution (repeatable; sourced after `--with-server-env`)
  - `MCPBASH_RUN_TOOL_SOURCE_SERVER_ENV=1`: Environment variable to implicitly enable `--with-server-env` for all invocations
  - `--print-env` now shows `WILL_SOURCE_SERVER_ENV` and `WILL_SOURCE[N]` for debugging without execution
- **Debug enhancements**:
  - `MCPBASH_FRAMEWORK_VERSION`: New read-only env var exposing framework version (from `${MCPBASH_HOME}/VERSION`) at startup. Useful for consuming projects to log version banners without file reads.
  - Client identity logging: When `MCPBASH_LOG_LEVEL=debug`, the server now logs connecting client's name/version at initialize (e.g., `Client: claude-ai/0.1.0 pid=12345`). Helps identify which mcp-bash process serves which client when multiple instances run.

### Changed

### Fixed


## [0.9.2] - 2026-01-05

### Added
- **CallToolResult response helpers**: New SDK functions for building MCP CallToolResult responses with consistent `{success, result}` envelope patterns:
  - `mcp_result_success` - Emit success CallToolResult with `structuredContent.success=true` and `isError=false`
  - `mcp_result_error` - Emit error CallToolResult with `structuredContent.success=false` and `isError=true`
  - `mcp_json_truncate` - Binary-search truncation for large JSON arrays with metadata (`truncated`, `kept`, `total`)
  - `mcp_is_valid_json` - Validate single JSON value (handles `false`/`null` correctly via slurp mode)
  - `mcp_byte_length` - UTF-8 safe byte length measurement
- Documentation: Added BEST-PRACTICES.md §4.7 "Building CallToolResult responses" with examples and comparison table. Added "Capturing stdout and stderr separately" pattern to §4.3 for CLI wrapper tools.
- Tests: Unit tests (`test/unit/sdk_result_helpers.bats`) and integration tests (`test/integration/test_result_helpers.sh`) for all new helpers.

### Changed
- **Test framework modernization**: Unit tests now use proper bats-core syntax with `@test` functions (219 tests across 40 files). Migrated from custom test runner to direct bats invocation with parallel execution support (`--jobs N` when GNU parallel available). Bats helper libraries (bats-support, bats-assert, bats-file) installed via npm instead of vendored. CI now outputs JUnit XML for test result visualization.
- **Examples updated to best practices**: All examples now use `mcp_result_success` / `mcp_result_error` helpers instead of legacy `mcp_emit_json` patterns, with corresponding `outputSchema` updates using the `{success, result}` envelope.
- **Scaffold templates updated**: Tool scaffolds (`scaffold/tool/`, `mcpbash init` inline template) now generate code using `mcp_result_success` with proper `outputSchema` envelope pattern.
- **Documentation examples updated**: ERRORS.md and BEST-PRACTICES.md code examples now demonstrate the recommended `mcp_result_success` / `mcp_result_error` patterns.
- **ffmpeg-studio examples**: Added stderr capture for better error reporting in `extract` and `inspect` tools.

### Fixed
- **CallToolResult passthrough**: Framework now detects when tools emit pre-formatted CallToolResult JSON (from `mcp_result_success` / `mcp_result_error`) and uses it directly instead of wrapping it again. The `outputSchema` validation now correctly validates `structuredContent` from CallToolResult outputs.

## [0.9.1] - 2026-01-03

### Added
- Installer now uses exit code 3 for policy refusal (user declined prompt or `MCPBASH_HOME` is set), allowing CI/CD scripts to distinguish "user/policy declined" from actual failures (exit 1).
- Installer help text now documents exit codes (0=success, 1=error, 2=invalid args, 3=policy refusal).
- README now includes installer exit codes table and CI/CD installation patterns (tarball+SHA256 and git+SHA verification).

### Fixed
- Installer color escape codes now render correctly (use `$'\033[...]'` syntax instead of single-quoted literals).
- Installer now prompts interactively via `/dev/tty` when run via `curl | bash`, instead of auto-confirming overwrites.
- Installer messaging clarifies when auto-confirm is due to `--yes` flag vs no TTY available.
- Installer verification error messages now include filename, expected/actual SHA values, and guidance on possible causes (corrupted download, MITM attack, version mismatch).

## [0.9.0] - 2026-01-03

### Added
- **MCPB bundle support**: `mcp-bash bundle` creates distributable `.mcpb` packages for one-click installation in MCPB-compatible clients (e.g., Claude Desktop). Bundles include the embedded framework, tools, resources, prompts, and a generated manifest following MCPB specification v0.3.
- **`mcp_with_retry` SDK helper**: Retry commands with exponential backoff + jitter for transient failures. Exit codes 0-2 are not retried (permanent); 3+ trigger retry. Example: `mcp_with_retry 3 1.0 -- curl -sf "$url"`.
- **Health checks hook**: Optional `server.d/health-checks.sh` verifies external dependencies (CLIs, env vars) before serving. Helpers `mcp_health_check_command` and `mcp_health_check_env` report results to `mcp-bash health` output as `projectChecks: ok|failed`.
- Optional `mcpb.conf` configuration file for customizing bundle metadata (name, version, author, repository). Values fall back to `server.d/server.meta.json`, `VERSION` file, and git config.
- Automatic icon inclusion: `icon.png` or `icon.svg` in project root is bundled for client UI display.
- **Platform-specific builds**: `mcp-bash bundle --platform darwin|linux|win32|all` creates bundles targeting specific platforms.
- **gojq bundling**: `mcp-bash bundle --include-gojq` embeds gojq binary for systems without jq installed.
- **Registry publishing**: `mcp-bash publish` command submits bundles to the MCP Registry with validation, dry-run support, and API token authentication.
- New documentation: `docs/MCPB.md` covers bundle creation, configuration, structure, publishing, and troubleshooting.
- GitHub Actions workflow `.github/workflows/bundle.yml` for CI testing of bundle creation across platforms.
- Example Makefile with `make bundle` target in `examples/00-hello-tool/`.
- Unit tests for `bundle` and `publish` commands.
- Pre-commit hook for automatic README.md rendering from template.

### Changed
- Renamed default icon from `assets/icon.svg` to `assets/mcp-bash-framework-icon.svg` for clarity.
- `mcp-bash new` now includes `mcp-bash bundle` in the "Next steps" output.

### Fixed
- Project root detection now recognizes valid projects under `MCPBASH_HOME` (e.g., `examples/`) by checking for `server.d/server.meta.json` before skipping framework-internal paths.
- Unknown CLI commands now display an error message instead of silently entering server mode.
- `registry status` and `registry refresh` subcommands now exit properly instead of falling through to "Unknown command" error.
- MCPB bundles now include `lib/` and `providers/` directories when present in the project.

### Documentation
- Added "Calling external CLI tools" section to BEST-PRACTICES.md with safe jq pipeline patterns, fallback defaults table, and error preservation patterns.
- Added "Retry with exponential backoff", "Parallel external calls", and "Rate limiting external APIs" patterns to BEST-PRACTICES.md.
- Added "External dependency health checks" section documenting the `server.d/health-checks.sh` hook.
- Added jq parse error troubleshooting entry to ERRORS.md with cross-reference to BEST-PRACTICES.md.
- Added server hooks table to PROJECT-STRUCTURE.md documenting all `server.d/` hook files.

## [0.8.4] - 2026-01-01

### Added
- **Project-level resource providers**: Projects can now define custom resource providers in `${MCPBASH_PROJECT_ROOT}/providers/`. Project providers are checked before framework providers, enabling custom URI schemes (e.g., `xaffinity://`, `myapi://`) without modifying the framework installation. See `docs/REGISTRY.md` for details.
- New environment variable `MCPBASH_PROVIDERS_DIR` for overriding the providers directory location.

### Fixed
- Shell profile sourcing now loads all relevant profiles (`.zprofile`, `.zshrc`, `.bash_profile`, `.profile`, `.bashrc`) instead of only the first one found. Ensures version managers like pyenv, nvm, and rbenv are properly available when MCP servers are launched from GUI applications like Claude Desktop.
- `config --wrapper` and `--wrapper-env` now work on macOS system bash (3.2) by avoiding heredocs inside command substitutions.

## [0.8.3] - 2025-12-26

### Added
- `mcp-bash validate` now validates icons format per MCP spec: icons must be objects with `src` property, not plain strings. Catches the common "expected object, received string" error that causes strict MCP clients (Cursor, Claude Desktop, MCP Inspector) to reject servers.
- `mcp-bash validate --inspector` flag prints the command to run MCP Inspector CLI for strict schema validation.

### Documentation
- Added "Common Schema Errors" section to DEBUGGING.md documenting icons format errors and strict client validation failures.
- Added troubleshooting flowchart to DEBUGGING.md for diagnosing "works from CLI but fails in clients" issues.

## [0.8.2] - 2025-12-23

### Added
- Tools now receive a per-invocation debug log path via `MCPBASH_DEBUG_LOG`; the SDK exposes `mcp_debug` to write to it.
- Output schema validation errors can include diagnostic metadata when `MCPBASH_DEBUG_ERRORS=true`.

### Fixed
- Tool tracing on bash 3.2 now reconstructs trace logs from stderr to avoid empty trace files on macOS runners.

### Documentation
- Documented the new debug log channel and opt-in error diagnostics.

## [0.8.1] - 2025-12-20

### Added
- `mcp-bash doctor`: added `--dry-run` (propose actions) and `--fix` (managed-install-only repairs), plus `--min-version`/`--archive`/`--verify`/`--ref` upgrade inputs, a concurrency lock, and JSON contract fields `schemaVersion`, `exitCode`, `findings`, `proposedActions`, and `actionsTaken`.
- Installer now writes `INSTALLER.json` into managed installs so `doctor --fix` can reliably distinguish managed vs user-managed installs.

### Fixed
- Windows/Git Bash: registry builds no longer pass large item payloads via `--argjson`, avoiding `E2BIG`/`Argument list too long` failures when icons are inlined.

### Documentation
- Clarified resource template discoverability: templates are listed via `resources/templates/list` and are not advertised via a dedicated capabilities flag; clients should probe the method (treat `-32601` as unsupported).

## [0.8.0] - 2025-12-16

### Added

### Changed
- Tool environment isolation no longer spawns external `env`; uses bash built-ins (`compgen -e`, `unset`) to avoid `E2BIG`/`Argument list too long` failures on Windows/Git Bash with large environments.
- **BREAKING**: Completion/resource providers now run under a curated environment by default (`MCPBASH_PROVIDER_ENV_MODE=isolate`) to reduce `E2BIG` risk; opt into inheritance with `MCPBASH_PROVIDER_ENV_MODE=inherit` + `MCPBASH_PROVIDER_ENV_INHERIT_ALLOW=true` or selectively pass variables via `MCPBASH_PROVIDER_ENV_MODE=allowlist`.
- **BREAKING**: `completion/complete` requests are now **spec-shape only** (MCP `2025-11-25`: `params.ref` + `params.argument`). The legacy `params.name`/`params.arguments` shape is no longer accepted.
- **BREAKING**: Prompt templating only substitutes `{{var}}` placeholders from `prompts/get` arguments; other placeholder syntaxes are treated as literal text.
- CI: Windows integration runs default to non-verbose output and use a PR allowlist to reduce runtime; scheduled runs keep the full suite with per-test timeouts and better log preservation on cancellation.
- When `MCPBASH_PRESERVE_STATE=true`, per-request worker stderr logs (`stderr.*.log`) are preserved for debugging.
- Dev: Unit test runner supports filtering and enforces per-test timeouts (`MCPBASH_UNIT_TEST_TIMEOUT_SECONDS`) to avoid hangs and orphaned subprocesses.

### Fixed
- `mcp-bash validate` no longer warns about directory/tool name mismatches when tool names use the server namespace prefix with camelCase (e.g., `git-hex-cherryPickSingle` in a `cherry-pick-single` directory). The validator now strips the server name prefix from `server.meta.json` before comparing.
- Error-path JSON stderr logs no longer print full request payloads on parse/extract failures; logs now include bounded, single-line summaries (bytes/hash/excerpt).
- Tool tracing no longer dumps full args/_meta payloads into xtrace output for SDK helpers; traces remain usable while reducing accidental secret leakage.
- Completion results are now spec-shaped: `result.completion.values` is emitted as `string[]` (MCP `2025-11-25`).
- Completion providers, resource providers, and prompt rendering no longer rely on spawning external `env` in their execution paths (improves Windows/Git Bash reliability with large environments).
- CI env snapshots no longer rely on spawning external `env` when estimating environment size.
- Resource provider execution no longer breaks under Bash 3.2 `set -u` when running in curated environments (fixes macOS CI integration failures).
- Windows/Git Bash: curated provider env scrubbing is faster (batch unsets), avoiding provider-suite timeouts under very large environments.
- Windows/Git Bash: provider isolation no longer preserves arbitrary `MCPBASH_*` variables (reduces env bloat); use `MCPBASH_PROVIDER_ENV_MODE=allowlist` to pass custom `MCPBASH_*` variables to providers.

### Documentation
- Expanded MCP Inspector troubleshooting (origin allowlist + large `PATH` causing connect failures) and clarified completion request shape expectations in completion docs/examples.
- Updated `examples/10-completions` to include a demo prompt so completions can be exercised directly from the MCP Inspector UI (Prompts tab).
- Fixed minor README grammar in the run-tool section.

## [0.7.0] - 2025-12-13

### Documentation
- Clarified Windows support: Git Bash is CI-tested; WSL works like Linux but is not separately validated in CI.
- README MCP spec coverage table now marks Resources as fully supported (templates/binary included).
- Fixed `docs/ERRORS.md` examples to reflect that `result.isError=true` is derived from a non-zero tool exit.
- Added `docs/INSPECTOR.md` with MCP Inspector recipes and strict-client schema/shape pitfalls.
- Clarified completion script argument parsing: `MCP_COMPLETION_ARGS_JSON` is `params.arguments` (use `.query` / `.prefix`).

### Added
- Declarative project registration via `server.d/register.json` (data-only alternative to `server.d/register.sh`) with strict validation, safe-permissions checks, and per-kind override semantics.
- `mcp-bash run-tool` now supports per-invocation allowlisting via `--allow-self`, `--allow <tool>`, and `--allow-all`.
- Installer verification flag `--verify` to validate downloaded archives against published SHA256 checksums; pairs with release-published tarball and SHA256SUMS.
- Installer `--archive` flag to install from a local tar.gz (or URL) after verifying it externally (or via `--verify`).
- GitHub Actions release workflow (tag-triggered) builds a tarball and publishes SHA256SUMS for installer verification.
- Release prep automation: `scripts/bump-version.sh`, `scripts/render-readme.sh`, and a `Prepare Release` workflow to open a PR that bumps `VERSION` and re-renders `README.md`.
- CI/release guards: validate that `VERSION` matches the tag and that `README.md` is rendered from `README.md.in` for the release version.
- Unified test wrapper `test/run-all.sh` to sequence lint/unit/integration/examples/stress/smoke suites with skip flags.
- Windows Git Bash/MSYS guidance surfaced in `mcp-bash doctor` (stdout and `--json`) to set `MCPBASH_JSON_TOOL=jq` and `MSYS2_ARG_CONV_EXCL="*"`.
- Documentation updates: README troubleshooting section, installer verification example, allowlist env mode examples in README/ENV_REFERENCE, CI-mode guidance in CONTRIBUTING.
- Resource templates: auto-discovery of `uriTemplate` metadata, manual registration helpers, `.registry/resource-templates.json` cache with hash-based pagination, and shared `resources/list_changed` notifications. New example and docs cover client-side expansion and collision rules.
- Documentation updates: clarified batching (legacy/opt-in) in `SPEC-COMPLIANCE.md`, noted minimal mode capability omissions, added `docs/README.md` index and project structure clarifications, documented `resources/subscribe` notification shape, and added registry-size guidance in `PERFORMANCE.md`.
- Windows CI guidance in `docs/WINDOWS.md` recommends jq overrides (`MCPBASH_JSON_TOOL=jq`, `MCPBASH_JSON_TOOL_BIN=$(command -v jq)`) to avoid gojq exec-limit failures on GitHub Actions runners.
- `mcp-bash scaffold completion <name>` generates a starter completion script, registers it in `server.d/register.sh`, and wires a default timeout.

### Changed
- Installer `--verify` for tagged releases now targets the release-published tarball (`releases/download/vX.Y.Z/mcp-bash-vX.Y.Z.tar.gz`) so it stays in sync with the `SHA256SUMS` asset.
- Tagged archive installs now attempt to verify against `SHA256SUMS` automatically when available (without requiring `--verify`).
- Outgoing request IDs are now allocated via a lock-backed counter in the state dir to prevent cross-process ID reuse; elicitation polling in the flusher uses the shared counter.
- Background workers now start lazily: resource subscription polling begins on first `resources/subscribe`, and the progress flusher runs only when live progress is enabled or elicitation is supported (reduces overhead on Windows runners).
- All example tool/resource names switched to hyphenated form to match the validated naming regex.
- Server now advertises the spec-compliant `completions` capability in initialize responses; tests assert capability presence.
- Tool metadata parsing consolidates to a single jq pass per meta file, reducing per-tool process overhead during registry scans.
- Scaffolded tool template now treats `name` as optional with a default, matching the description.
- JSON tool detection now prefers jq over gojq, supports explicit MCPBASH_JSON_TOOL(_BIN) overrides, and validates candidates via `--version` before enabling full protocol mode.
- CI env snapshot now runs after JSON tool detection and records PATH/env byte sizes plus `jsonTool`/`jsonToolBin` metadata (counts only; no env contents captured).
- JSON-RPC batch handling is now protocol-aware: protocol `2025-03-26` auto-accepts batch arrays; newer protocols reject arrays unless `MCPBASH_COMPAT_BATCHES=true` is set for legacy clients, with clearer error messaging.
- Worker wait loop sleep increased to reduce busy-wait CPU churn when slots are full.
- Security hardening: git provider now requires allowlists, canonicalizes repo paths, and pre-checks disk space; HTTPS provider resolves hosts and blocks obfuscated private IPs; remote token guard enforces 32+ char secrets, throttles failures, and redacts tokens in debug logs; `MCPBASH_TOOL_ENV_MODE=inherit` now requires explicit opt-in via `MCPBASH_TOOL_ENV_INHERIT_ALLOW=true`; JSON tool overrides are ignored for root unless explicitly allowed (`MCPBASH_ALLOW_JSON_TOOL_OVERRIDE_FOR_ROOT=true`); tool metadata parsing no longer uses eval.
- **BREAKING**: Project registry hooks are now disabled by default; set `MCPBASH_ALLOW_PROJECT_HOOKS=true` to execute `server.d/register.sh`. Hooks are refused if the file is group/world writable or ownership mismatches the current user.
- **BREAKING**: Tool execution now defaults to deny unless explicitly allowlisted via `MCPBASH_TOOL_ALLOWLIST` (set to `*` to allow all in trusted projects). Paths are validated for ownership and safe permissions before execution.
- Debug payload redaction now scrubs common secret keys beyond `remoteToken`.
- Installer/docs now prefer verified downloads over `curl | bash` (one-liner retained as a labeled fallback).
- List endpoints now report total counts via `result._meta["mcpbash/total"]` (and no longer emit a top-level `total`) for stricter MCP client compatibility.
- `resources/subscribe` now returns only `{subscriptionId}` (spec-shaped) instead of including extra fields.
- `notifications/resources/updated` is now spec-shaped and emits only `params.uri`; clients should call `resources/read` to fetch updated content.
- Completion results no longer include the non-spec `result._meta.cursor` field (use `result.completion.nextCursor`).
- HTTPS provider is now deny-by-default for public hosts: set `MCPBASH_HTTPS_ALLOW_HOSTS` (preferred) or `MCPBASH_HTTPS_ALLOW_ALL=true` to permit outbound HTTPS fetches; URL host parsing strips userinfo to prevent SSRF bypasses.
- HTTPS provider no longer falls back to wget; curl is required to support DNS pinning via `--resolve`.
- Git provider path canonicalization now fails closed without `realpath` or `readlink -f` to prevent symlink-based escapes.
- Git provider now only accepts `git+https://` URIs (plaintext `git://` removed).

### Fixed
- Manual registration hook size-limit errors now set status for `resourceTemplates` consistently.
- JSON-RPC handlers no longer emit error `code: 0` when underlying registry failures occur (falls back to `-32603`).
- Removed duplicate YAML meta from the progress-and-cancellation example (JSON is canonical).
- Windows CI failures caused by `gojq` `E2BIG` exec errors are avoided by the jq-first detection order and exec sanity check.
- Windows Git Bash example flakiness: runtime now guarantees `MCPBASH_STATE_DIR`/`MCPBASH_LOCK_ROOT` exist (with a short-path fallback), and example tests capture server stderr and fail fast on shutdown watchdog timeouts or `mktemp` template failures.
- Progress/log streaming is more reliable across platforms: portable byte offsets in the flusher and explicit flushes before worker cleanup reduce missing tail output.
- HTTPS provider pins curl connections to vetted IPs via `--resolve` to mitigate DNS rebinding SSRF between pre-check and fetch.
- Registry refresh-path and git repo-root containment checks now use literal (non-glob) prefix comparisons to avoid metacharacter bypasses.
- Debug payload redaction now scrubs common secret keys across the full JSON payload (not only `_meta`) to reduce accidental leakage during debugging.
- `mcp_json_trim` rewritten to avoid O(n^2) trimming on large payloads.
- Shutdown finish branch corrected to prevent a syntax error in staged environments.
- `MCPBASH_SHUTDOWN_TIMEOUT=0` is now treated as "use the default" to avoid accidental zero-timeout shutdowns.
- `tools/call` now returns `-32602` (Invalid params) for tool not found, instead of `-32601` (Method not found), for JSON-RPC spec compliance.
- `resources/read` now returns `-32002` (Resource not found) for missing resources, instead of `-32601` (Method not found), per MCP spec.
- Resource providers no longer require the executable bit (more reliable on Git Bash/MSYS and some filesystems).
- Git Bash CRLF handling: strip `\r` from env passthrough and metadata keys to prevent subtle Windows-only failures.
- Completion scripts and custom providers work more reliably across platforms.
- JSON-RPC error responses omit `id` when the request `id` is invalid/unknown (strict JSON-RPC compliance).

## [0.6.0] - 2025-12-08

### Added
- Documentation discoverability improvements: README now links feature guides (elicitation, roots, registry, limits, errors, best practices, completions) and a new `docs/COMPLETION.md` covers completion providers, pagination, and script contracts.
- New example `examples/10-completions` demonstrating manual completion registration, query filtering, and hasMore/cursor pagination; included in the examples ladder.
- Comprehensive MCP Feature Support Matrix in `SPEC-COMPLIANCE.md` tracking all MCP features across protocol versions (2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25) with mcpbash version support status. Table includes 60+ features with implementation status, notes, and version history.
- Request metadata (`_meta`) support for `tools/call`: clients can now pass arbitrary metadata via `params._meta` which is exposed to tools as `MCP_TOOL_META_JSON` (or `MCP_TOOL_META_FILE` for large payloads). SDK helpers `mcp_meta_raw` and `mcp_meta_get` provide easy access. Use cases: pass auth context, rate limiting IDs, or behavior flags not generated by the LLM.
- Tools can now return embedded resources in results: write paths (optional mime/uri) to `MCP_TOOL_RESOURCES_FILE` and the framework will emit `type:"resource"` entries, including binary-safe handling.
- Resource reads detect binary MIME and emit base64 `blob` payloads instead of raw text to prevent malformed JSON on binary files.
- Tool errors now include structured exit codes and bounded stderr tails in `error.data` (mirrored in `_meta.stderr`); timeout responses surface the actual exit status and tail. Tunables: `MCPBASH_TOOL_STDERR_CAPTURE`, `MCPBASH_TOOL_STDERR_TAIL_LIMIT`, `MCPBASH_TOOL_TIMEOUT_CAPTURE`.
- Optional tool tracing: set `MCPBASH_TRACE_TOOLS=true` to enable `set -x` traces for shell tools with configurable `PS4` (`MCPBASH_TRACE_PS4`) and trace size cap (`MCPBASH_TRACE_MAX_BYTES`); traces are written under `MCPBASH_STATE_DIR`.
- CI mode enhancements: `MCPBASH_CI_MODE` now sets safe defaults (tmp root, log dir, keep-logs, timestamped logs, optional debug via `MCPBASH_CI_VERBOSE`), writes `failure-summary.jsonl` and `env-snapshot.json` under the log dir, and emits GitHub Actions `::error` annotations when tracing provides file/line.
- Tool annotations support (MCP 2025-03-26): tools can declare behavior hints (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`) in `.meta.json` or inline `# mcp:` comments. Annotations are surfaced in `tools/list` responses for clients to present appropriate UI cues.
- Shared-secret guard for proxied runs: set `MCPBASH_REMOTE_TOKEN` (default `_meta["mcpbash/remoteToken"]`, configurable key, timing-safe compare) to reject unauthenticated requests with `-32602`.
- Readiness/health probe: `mcp-bash --health|--ready [--project-root DIR] [--timeout SECS]` refreshes registries without side effects and exits `0/1/2` for probes.

### Changed
- **BREAKING**: Installer now uses XDG Base Directory compliant paths. Framework installs to `~/.local/share/mcp-bash` (or `$XDG_DATA_HOME/mcp-bash`) with a symlink at `~/.local/bin/mcp-bash`. Previous default was `~/mcp-bash-framework`. Users upgrading should either re-run the installer (which will use the new location) or specify `--dir ~/mcp-bash-framework` to keep the old path.
- Roots handling is quieter and stricter: fallback roots load immediately (env → config/roots.json → project root), client timeouts keep the existing cache without noisy warnings, roots must exist/read, drive letters are normalized for Windows/MSYS, and `run-tool --roots`/`MCPBASH_ROOTS` fail fast on invalid paths.
- `config --show` now prefixes each client snippet with a heading to make the target client clear; docs call out the multi-client output and `--client`/`--json` filters.
- Documentation updated to reflect MCP protocol version `2025-11-25` as the current target (was `2025-06-18`); the runtime now targets `2025-11-25` by default, and README/SPEC-COMPLIANCE.md include links to all supported protocol versions.
- Environment surface simplified: runtime timeout defaults use a single tier (30s tool, 120s subscribe, 5s shutdown), dead `MCPBASH_PROCESS_GROUP_WARNED` removed, README optional config trimmed to essentials, and a new authoritative `docs/ENV_REFERENCE.md` lists all user-facing knobs with defaults/caps.
- Tool invocations now log arguments, timeout, meta keys, roots, and trace status to the `mcp.tools` logger for easier diagnostics.

### Fixed
- `mcp-bash` now resolves symlinked launchers correctly, restoring accurate version detection and wrapper path handling when the binary is invoked via symlinks.
- `mcp-bash doctor` verifies the configured temporary root (`MCPBASH_TMP_ROOT` when set) is writable and reports misconfigurations instead of proceeding silently.

## [0.5.0] - 2025-12-08

### Added
- Protocol version `2025-11-25` support for compatibility with MCP Inspector v0.17+ and latest MCP SDK.
- Icons support for tools, resources, and prompts (SEP-973): add an `icons` array to any `.meta.json` file to provide visual identifiers in compatible clients. Icons are passed through in `tools/list`, `resources/list`, and `prompts/list` responses. Local file paths (e.g., `"./icon.svg"`) are automatically converted to data URIs for stdio transport compatibility.
- Documentation on Protocol Errors vs Tool Execution Errors (SEP-1303): `ERRORS.md` and `BEST-PRACTICES.md` now explain when to use each error type to enable LLM self-correction. Examples updated to demonstrate best practices.
- Elicitation SDK helpers for SEP-1330 enum improvements: `mcp_elicit_titled_choice` (choices with display labels) and `mcp_elicit_multi_choice` / `mcp_elicit_titled_multi_choice` (multi-select checkboxes). The 08-elicitation example demonstrates all patterns.
- SEP-1036 URL mode elicitation support: `mcp_elicit_url` helper for secure out-of-band interactions (OAuth, payments, sensitive data). The framework now detects client form/url mode capabilities and includes `mode` in elicitation requests.
- `mcp-bash config --inspector` prints a ready-to-run MCP Inspector command (stdio transport) with `MCPBASH_PROJECT_ROOT` pre-populated for the current project.
- Test session helper `test/common/session.sh` for sequential interactive tool calls in tests; documented in `TESTING.md` (note: skips notifications, overwrites EXIT traps).
- `mcp-bash config --wrapper-env` generates a wrapper that sources `.zshrc`/`.bash_profile`/`.bashrc` before exec (for Claude Desktop macOS non-login shells).
- `mcp-bash doctor` detects macOS `com.apple.quarantine` on the framework binary and project path and prints remediation commands; helper script `scripts/macos-dequarantine.sh` added.
- README and debugging docs include macOS Claude Desktop troubleshooting (PATH/env gaps, quarantine clearing, wrapper guidance).
- `validate` warns when tool names lack a namespace-style prefix (e.g., `myproj-hello`) to encourage safer naming.

### Fixed
- Unsupported protocol version errors now include the requested version and list of supported versions for easier debugging.
- Startup diagnostics detect stdio transport and log to stderr (transport, cwd, project root, JSON tool) to keep stdout JSON-only for clients.
- README OpenAI Agents SDK example matches the current `MCPServerStdio` signature (no `name` kwarg, optional args/env/cwd shown).
- README notes that client configs can point to generated wrapper scripts (`config --wrapper`/`--wrapper-env`) instead of the raw binary.
- README clarifies when to choose `config --wrapper` vs `--wrapper-env` and how to distribute both options (GUI vs CI/Linux).

### Changed
- Replaced `mcp-bash scaffold server` with `mcp-bash new <name> [--no-hello]`; server scaffolding now lives under the new command and `scaffold server` is removed.
- `mcp-bash config --wrapper` now creates `<project-root>/<server-name>.sh` and `chmod +x` when stdout is a TTY (with filename validation and collision checks) while preserving stdout output for piped/redirected use; help/docs/tests updated.
- Documentation clarifies the MCP name regex (alphanumeric, underscores, hyphens only) and switches tool examples to hyphenated names to match the limitations of some clients; `validate` now warns on names outside the supported regex and scaffolding rejects dotted names up front.
- JSON tooling detection success logs are quiet by default; set `MCPBASH_LOG_JSON_TOOL=log` or `MCPBASH_LOG_VERBOSE=true` to surface them. Minimal-mode warnings still emit when JSON tooling is missing.
- Startup summary log is suppressed by default; set `MCPBASH_LOG_STARTUP=true` or `MCPBASH_LOG_VERBOSE=true` to print it.

## [0.4.0] - 2025-12-06

### Added
- SDK helper `mcp_require_path` for consistent path normalization, optional single-root defaulting, and roots enforcement in tools.
- SDK type coercion helpers (`mcp_args_bool`, `mcp_args_int`, `mcp_args_require`) for common argument parsing patterns.
- Shared path normalization helpers (`lib/path.sh`) with consistent fallback chain (realpath -m → realpath → readlink -f → manual collapse) used by SDK/runtime/installer; added unit coverage.
- CLI `run-tool` command for direct tool invocation with optional roots, dry-run, timeout override, and verbose stderr streaming.
- Installer supports `--version`/`--ref` aliases for tagged installs and auto-prefixes bare semver tags with `v`.
- CLI `run-tool --print-env` to inspect wiring without executing tools; help/examples updated.
- `mcp-bash validate` now supports `--json`, `--explain-defaults`, and `--strict`; tool naming validation warns on missing namespace/format/length; outputs include defaults in JSON.
- `mcp-bash config` gains richer `--json` output, pasteable JSON for `--client`, and `--wrapper` generator for auto-install scripts.
- `mcp-bash registry status` subcommand to inspect registry cache (hash/mtime/counts) without refresh.
- `mcp-bash doctor --json` for machine-readable environment/project readiness (absorbs readiness summary).
- Tool policy hook (`server.d/policy.sh` + `mcp_tools_policy_check`) invoked before every tool run; default allows all, enabling read-only/allowlist/audit policies without per-tool code.
- Docs for `run-tool` usage/flags and unit coverage for the CLI wrapper.
- `mcp-bash scaffold test` CLI to generate a minimal test harness (`test/run.sh`, `test/README.md`) wrapping `run-tool`, plus integration coverage.

### Fixed
- Manual tool registry refresh now respects hook exit codes: status 1 falls back to a scan, status 2 surfaces as fatal, and missing manual registry files no longer block refresh.
- Stderr streaming no longer re-executes tools on non-zero exits; if process substitution is unavailable, stderr is buffered once with a single notice.
- Stderr buffering now appends across retries/streams to preserve diagnostic output when streaming is unavailable.
- `mcp-bash doctor --json` escapes values before emitting JSON, avoiding malformed output when paths contain quotes or spaces.
- `mcp-bash config --json` escapes server names/paths, preventing invalid snippets for clients.
- `mcp-bash run-tool --no-refresh/--args` now fails fast with a clear error when JSON tooling is unavailable instead of dying later.

### Changed
- CLI commands (`init`, `validate`, `config`, `doctor`, `run-tool`, `registry refresh`, `scaffold`) moved into `lib/cli/*.sh` with a thin dispatcher in `bin/mcp-bash`; shared helpers live in `lib/cli/common.sh`. Behavior unchanged, startup parse overhead slightly reduced.

## [0.3.0] - 2025-12-05

### Added
- CLI project tooling for standalone servers:
  - `mcp-bash init [--name NAME] [--no-hello]` initializes a project in the current directory with `server.d/server.meta.json`, a `tools/` directory, a `.gitignore`, and a working `hello` tool by default.
  - `mcp-bash scaffold server <name>` creates a new project directory with the same structure and example tool, wired to the existing scaffold templates.
  - `mcp-bash validate [--project-root DIR] [--fix]` validates server metadata and all tools/prompts/resources (JSON shape, required fields, script presence, executability, basic schema checks) and can auto-fix missing executable bits.
  - `mcp-bash config [--project-root DIR] [--show|--json|--client NAME]` emits ready-to-paste MCP client configuration snippets (Claude Desktop/CLI, Cursor, Windsurf, LibreChat) and a machine-readable JSON descriptor including `MCPBASH_PROJECT_ROOT`.
  - `mcp-bash doctor` performs environment diagnostics (framework location/version, PATH wiring, jq/gojq availability, basic project metadata, shellcheck/npx presence).
- One-line installer script `install.sh`:
  - Clones the framework into a safe, dedicated install directory, configures shell PATH for common shells, verifies `mcp-bash --version`, and warns when jq/gojq is missing.
  - Supports `--dir`, `--branch`, and `--yes` flags for CI and advanced setups.
- New SDK JSON helpers in `sdk/tool-sdk.sh`:
  - `mcp_json_escape` for quoting strings as JSON string literals.
  - `mcp_json_obj` / `mcp_json_arr` for building simple string-keyed objects and string-only arrays, using gojq/jq when available with a safe fallback when not.
- Test coverage for the new behavior:
  - Unit tests for the SDK JSON helpers.
  - Integration tests for the new CLI commands (`init`, `validate`, `config`, `doctor`) and their happy-path behavior across platforms.

### Changed
- Project root handling:
  - Runtime now auto-detects `MCPBASH_PROJECT_ROOT` by walking up from the current directory to find `server.d/server.meta.json`, explicitly skipping framework-internal paths (bootstrap, examples, scaffold).
  - CLI commands that require a project (`scaffold tool/prompt/resource`, `validate`, `config`, `registry refresh`) now work out of the box inside a project directory without exporting `MCPBASH_PROJECT_ROOT`, while still honoring an explicit env var or `--project-root` when provided.
- Tool and example boilerplate:
  - Scaffolded tools and all shipped examples now use a minimal, canonical pattern: `source "${MCP_SDK:?...}/tool-sdk.sh"`, `mcp_args_get` for input, and the new `mcp_json_*` helpers for structured output, instead of in-repo `../../sdk` fallbacks and ad-hoc JSON builders.
  - `scaffold/tool/README.md` and example READMEs point to the new pattern and SDK helpers as the recommended starting point for standalone servers.
- Documentation and metadata:
  - `README.md` Quick Start updated to favor the installer, `mcp-bash init`, auto-detected project roots, `mcp-bash config`, and `mcp-bash doctor` as the primary workflow for third-party servers.
  - `docs/PROJECT-STRUCTURE.md` updated to reflect `init`/`scaffold server`, the presence of `server.d/server.meta.json` in minimal projects, and the simplified SDK discovery model.
  - `scaffold/server/server.meta.json` simplified to match the defaults produced by `mcp-bash init`/`mcp-bash scaffold server`, leaving optional fields like `websiteUrl`/`icons` for authors to add explicitly.
- Tool discovery now ignores root-level scripts under `tools/`; automatic discovery requires each tool to live in a subdirectory (for example `tools/hello/tool.sh` with `tools/hello/tool.meta.json`). This is a breaking change for projects that relied on flat layouts like `tools/foo.sh`.
- All bundled examples and stress/integration tests have been updated to use the per-tool directory layout, matching the scaffolder output (`mcp-bash scaffold tool <name>`).
- Documentation (README, best practices, registry contracts, LLM guide) no longer advertises flat layouts as supported; the canonical layout is `tools/<name>/tool.sh` + `tools/<name>/tool.meta.json`.

## [0.2.1] - 2025-12-03

### Changed
- Hardened HTTPS provider: blocks private/loopback hosts, optional host allow/deny via `MCPBASH_HTTPS_ALLOW_HOSTS` / `MCPBASH_HTTPS_DENY_HOSTS`, disables redirects/protocol downgrades, and caps timeouts/size (timeout ≤60s, max bytes ≤20MB).
- Hardened git provider: disabled by default (`MCPBASH_ENABLE_GIT_PROVIDER=true` to enable), host allow/deny lists added, private/loopback blocked, shallow clones enforced, timeout bounded (default 30s, max 60s), and repository size capped via `MCPBASH_GIT_MAX_KB` (default 50MB, max 1GB).
- Introduced shared host policy helper (`lib/policy.sh`) for consistent allow/deny handling across providers.
- Tightened state/lock/registry permissions with `umask 077`; debug mode now uses a randomized 0700 directory.
- File provider now rejects symlinks and rechecks before read to reduce TOCTOU/symlink escape risk.
- Scaffold commands validate names to prevent path traversal.
 - Added `llms.txt` and `llms-full.txt` for LLM-specific repository guidance and compressed, agent-optimized reference content.

## [0.2.0] - 2025-12-02

### Added
- Automatic getting-started mode when `MCPBASH_PROJECT_ROOT` is unset: stages a temporary bootstrap project with a `getting_started` tool, isolated registry cache, and cleanup traps (including HUP) plus clearer help text.
- Framework-only bootstrap helper content and docs updates (Quick Start and Project Structure) explaining the temporary helper and how to configure real projects.
- Integration coverage for the bootstrap path and stricter CLI guard for invalid project roots.
- Go module for gojq (`tools/go.mod`/`go.sum`) and CI caching: `setup-go` module cache plus `GOCACHE` restored, with gojq installed via the module for reproducible tooling across OSes.
- Tar-based test staging for integration/examples: shared `base.tar` with ACL-safe flags, reused across tests, reducing Windows I/O; integration tests now use the shared staging helper instead of per-test `cp -a`.
- Windows CI guardrails: duration gate now warns at 4m and fails at 15m only on warm caches; Windows path handling fixed for Go caches; minor prompt/resource/tool tests refactored to honor staging.
- Unified server metadata via `server.d/server.meta.json`: supports MCP spec fields `name`, `title`, `version`, `description`, `websiteUrl`, and `icons`. Smart defaults derive `name` from project directory, `title` from titlecase of name, and `version` from `VERSION` file or `package.json`.
- Framework `VERSION` file as single source of truth for version; `mcp-bash --version` and bootstrap helper now read from it.
- Default icon (`assets/icon.svg`) and full metadata for the bootstrap getting-started helper.

## [0.1.0] - 2025-11-30

### Added
- Stdio MCP server targeting protocol `2025-06-18` with negotiated downgrades to `2025-03-26` and `2024-11-05`.
- Core surfaces: lifecycle, ping, logging/setLevel, tools (list/call), resources (list/read/subscribe), prompts (list/get), completion, pagination, and `listChanged` notifications.
- Concurrency, cancellation, timeout watchdogs, stdout corruption guards, and JSON-tool detection with minimal-mode fallback.
- Registry system with TTL-based refresh, hash-based change detection, and manual registration hooks.
- Elicitation support (server/client detection, tool helper APIs) and roots integration (server-initiated roots/list with fallbacks).
- Tool SDK with logging/progress helpers, scaffolding commands for tools/resources/prompts, and example projects (hello tool, args/logging/progress/resources/prompts/elicitation/roots, advanced ffmpeg studio).
- Compatibility and integration tests (Inspector harness, integration suites), lint/test scripts, and docs covering architecture, security, limits, performance, and Windows guidance.
