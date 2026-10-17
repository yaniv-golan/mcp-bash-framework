# Elicitation Support in mcp-bash

Elicitation lets a tool pause execution, ask the MCP client for user input, and continue once a response arrives. It is supported when the client advertises `capabilities.elicitation` during `initialize`.

**Client support:** Claude Desktop does not advertise elicitation to installed extensions (`.mcpb`; checked in 2.31226.1); its remote connectors advertise URL mode only. In Desktop, the helpers' no-answer path is what runs, so design it as the main path (for example, require `confirm: true` in the arguments before a destructive action). That argument comes from the model, though, so it isn't the user's approval. In Desktop's agent sessions (Cowork and Code; checked in 2.42304.0), the user approves through Desktop's own card before a tool call. The card offers "Always allow" by default, which skips it for that tool from then on, across sessions and restarts, until the tool's definition changes (admins of third-party deployments can turn that off). It is also skipped after "Allow for this task", in bypass mode, and, in Cowork's Auto mode, for a tool annotated `readOnlyHint: true`, so never mark a tool that changes anything as read-only. `destructiveHint` doesn't make Desktop ask about an extension's tool.

## Server Behavior
- On initialize, the server records whether the client supports elicitation and which modes (`form`, `url`).
- When the client supports elicitation, the server runs a lightweight poller to watch for tool-written request files (`elicit.<key>.request`) and forwards them to the client as `elicitation/create` requests with the appropriate `mode`.
- Client responses are normalized to `{"action": "...", "content": ...}` and written to `elicit.<key>.response`.
- Requests pending per-worker are tracked so cancellation/cleanup can discard stale requests and late responses.

## Elicitation Modes (SEP-1036)

MCP 2025-11-25 introduces two elicitation modes:

| Mode | Use Case | Data Flow |
|------|----------|-----------|
| **form** | Collect non-sensitive input (choice, confirmation) | Data passes through client |
| **url** | OAuth, payments, sensitive data | Opens browser, data never touches client |

Client capability format:
```json
{"elicitation": {"form": {}, "url": {}}}
```

Legacy clients using `{"elicitation": {}}` are treated as form-only.

## Tool SDK Helpers

The SDK exposes helpers in `sdk/tool-sdk.sh`. Since 2.0 the question helpers are called **directly** (not inside `$(...)`), and their exit code is the answer:

- **exit 0**: the user accepted (for `mcp_elicit_confirm`: accepted **and** confirmed);
- **exit 1**: anything else, with the reason in `MCP_ELICIT_ACTION`: `decline` (a no, or `confirmed: false`), `cancel`, or `unavailable` (the client can't ask, the question timed out, or there is no JSON tool).

`-v VAR` puts the answer in the variable `VAR` (emptied when the answer isn't a yes; trailing newlines are kept). `--arg NAME` takes the answer from the tool's argument `NAME` when the call has a valid one, without asking: a client that can't ask (Claude Desktop extensions, scripts, CI) passes it in the arguments instead. `mcp_elicit_confirm` is the exception: it reads `--arg` only when the client can't ask. A client that can always asks the user, and a declined or unanswered question is not overridden by the argument. Where the client can't ask, including Claude Desktop extensions, `--arg` on a confirmation is still the model's answer: nobody else can give one.

Answers are checked: a choice must be one of the options offered (multi-choice: an array of distinct options), `mcp_elicit_string` takes a string, and `mcp_elicit_confirm` a real boolean. An invalid `--arg` value is ignored and the user is asked (`unavailable` if the client can't ask); an invalid or missing answer from the client is `unavailable`.

**`--arg` lets the tool's caller answer instead of the user.** The arguments come from the model, so use it only for values the model may legitimately supply (a name, an environment), never for a confirmation of something destructive: `mcp_elicit_confirm --arg confirmed "Delete 40 files?"` would let the model say yes without asking whenever the client can't ask. For those, call `mcp_elicit_confirm` without `--arg` and handle `unavailable` (for example, refuse and explain).

### Form Mode (in-band)
- `mcp_elicit_string [-v VAR] [--arg NAME] <message> [field_name]` — free-text input
- `mcp_elicit_confirm [--arg NAME] <message>` — yes/no boolean (see the `--arg` warning above)
- `mcp_elicit_choice [-v VAR] [--arg NAME] <message> opt1 opt2 ...` — radio buttons (single select)
- `mcp_elicit_titled_choice [-v VAR] [--arg NAME] <message> "val1:Label 1" "val2:Label 2"` — radio buttons with display labels (SEP-1330); the answer is the value
- `mcp_elicit_multi_choice [-v VAR] [--arg NAME] <message> opt1 opt2 ...` — checkboxes (multi-select, SEP-1330); the answer is a compact JSON array such as `["opt1","opt2"]`
- `mcp_elicit_titled_multi_choice [-v VAR] [--arg NAME] <message> "val1:Label 1" ...` — checkboxes with labels

```bash
if mcp_elicit_string -v name --arg name "Your name?"; then
    mcp_result_text "Hello, ${name}"
else
    case "${MCP_ELICIT_ACTION}" in
    decline | cancel) mcp_fail --type declined "No name given" ;;
    unavailable) mcp_fail --type invalid_args "Pass name in the arguments" ;;
    esac
fi
```

### URL Mode (out-of-band, SEP-1036)
- `mcp_elicit_url <message> <url> [timeout_secs]` — opens browser for OAuth/payments; exit 0 when the user accepted. The server gives each request a unique `elicitationId`, as the spec requires.

```bash
# Example: OAuth authorization
if mcp_elicit_url "Authorize with GitHub" "https://github.com/login/oauth/authorize?..."; then
    echo "User completed authorization" >&2
fi
```

### Raw helpers
`mcp_elicit <message> <schema_json> [timeout_secs] [mode]` and `mcp_elicit_url_raw <message> <url> [timeout_secs]` print the client's answer as JSON (`{"action": "...", "content": ...}`), for schemas the helpers above don't cover. Capture them with `$(...)` and branch on `.action`: `accept`, `decline`, `cancel`, or `unavailable` (since 2.0; 1.x printed `error` here, and `decline` when the client couldn't ask). They exit non-zero when no answer came back (`unavailable`, including a client that answered with an error, or `cancel` when the request was cancelled), so capture them with `|| true` under `set -e`.

### Calling them under `set -e`

Call the helpers in an `if` (or `if !`) or before `||`. A bare call under `set -euo pipefail` ends the tool on any answer but yes; `mcp-bash validate` and `migrate` flag such calls (rule `2-elicit-bare`). Don't name a `-v` variable with the SDK's prefixes (`__mcp_el_`, `_MCP_ELICIT_`) or `MCP_ELICIT_ACTION`; they are refused (`unavailable`), and so is a readonly variable.

`mcp_fail --type` ends the tool. `mcp_result_json` and `mcp_result_text` print the result but **do not exit**: in an early-return branch, follow them with `exit 0`, or the tool keeps running and prints a second result.

### Upgrading from 1.x

In 1.x the question helpers printed the `{"action": ...}` JSON, and tools captured it. In 2.0 they print nothing, so a 1.x capture **fails silently**: the tool keeps running, the captured text is empty, and the "not accepted" branch runs even when the user said yes. Rewrite before upgrading; `mcp-bash migrate` (and `validate`, which marks these findings as failing silently) lists every capture (rule `2-elicit-capture`). `validate` still exits 0 for deprecations, silent ones included; add `--deprecations-as-errors` to make a CI job fail on them.

```bash
# 1.x
resp="$(mcp_elicit_confirm "Delete 40 files?")" || true   # 1.x only (lint-api-usage: allow)
if [ "$(jq -r '.action' <<<"${resp}")" != "accept" ] || [ "$(jq -r '.content.confirmed' <<<"${resp}")" != "true" ]; then
    mcp_fail --type declined "Not confirmed"
fi

# 2.0
if ! mcp_elicit_confirm "Delete 40 files?"; then
    mcp_fail --type declined "Not confirmed (${MCP_ELICIT_ACTION})"
fi
```

## On the 2026-07-28 path: the tool runs again after a question

With `MCPBASH_MODERN_PROTOCOL=true`, a modern (2026-07-28) client can't be sent a request in the middle of a call. A question ends the call instead: the client gets a result with `resultType: "input_required"`, the question in `inputRequests` and a `requestState`, asks the user, and calls the tool again with the answer. The helpers are called the same way; what changes is that **the tool runs again from the start** on the second call, and this time the helper returns the answer.

So anything before the question runs twice, unless you wrap it in `mcp_once`:

```bash
build_id="$(mcp_once start_build "${target}")"   # runs once; replayed on the retry
if ! mcp_elicit_confirm "Deploy build ${build_id}?"; then
    mcp_fail --type declined "Not confirmed (${MCP_ELICIT_ACTION})"
fi
deploy "${build_id}"                              # after the question: runs once
```

- `mcp_once [--key NAME] CMD [ARG...]` runs CMD in a subshell the first time and records its stdout, stderr and exit status; on the retry it replays them without running CMD. Wrap anything before a question that has a side effect, is slow, or can give a different answer next time. A step runs in a subshell in every run, so `cd`, `export` and assignments inside it don't reach your script: compute a value with `mcp_once` and assign it outside, as above. On legacy clients, and outside a modern call, CMD simply runs.
- Steps and questions are matched by their position and their command line (or question). A run that takes another path than the one before ends in an error result of type `diverged` that names the step or question (not its command line, which can hold secrets), never with an answer meant for another question. `--key NAME` matches a step by name instead, for a command whose arguments change between runs (a timestamp, a token).
- Run steps and questions one after another: positions are counted in order, so steps started in parallel (`mcp_once a & mcp_once b & wait`) can get the same one.
- A step that was still running when the tool was stopped wasn't recorded, and runs again.
- Progress and log notifications sent before the question are sent again on the retry.
- `MCP_MRTR_ATTEMPT` is `1` on the first run, `2` on the retry, and so on: for logging, not to change what the tool does.
- This server process keeps the call's journal for `MCPBASH_MRTR_TICKET_TTL_SECS` (15 minutes) after each question. A retry after that, or after the server restarted, gets an error result of type `request_expired` (run the tool again); one with another tool or other arguments gets `request_mismatch`. Only one retry with a `requestState` runs at a time: a duplicate sent while it runs is asked the open question again, or gets `request_in_progress`. A run that was killed (not cancelled) leaves its call `request_expired`. The tool is never re-run silently, which could repeat a side effect. Each retry, answered or not, starts the TTL again, so a client that keeps retrying keeps the journal (one small directory per call).
- The `TIMEOUT` argument of `mcp_elicit` doesn't apply on this path: the call ends at the question, and the user has until the TTL to answer.
- A question is asked only when the request's `clientCapabilities` include `elicitation` (form, URL or both); otherwise the helpers answer `unavailable`, and `--arg` answers as on the legacy path. `mcp_elicit_confirm` never takes `--arg` from a client that can ask, nor on a retry (a call with a `requestState`): there the journal holds the user's answers, and a new question that this request can't ask answers `unavailable`.

## Environment Variables

Set for tools:
- `MCP_ELICIT_SUPPORTED` – `"1"` when the client supports elicitation, `"0"` otherwise.
- `MCP_ELICIT_REQUEST_FILE` – path to write a request (JSON: `{"message": "...", "schema": {...}, "mode": "form"}`).
- `MCP_ELICIT_RESPONSE_FILE` – where the normalized response appears.
- `MCP_MRTR_JOURNAL` – on a 2026-07-28 call whose client can answer questions: the call's journal (instead of the two files above).
- `MCP_MRTR_ATTEMPT` – with it: `1`, then `2` on the retry after a question, and so on.

The SDK handles writing/reading these files, timeouts, and cancellation. `MCP_ELICIT_ACTION` is set by the SDK in the tool's own shell after each question helper; the server doesn't set it.

## Examples
- `examples/08-elicitation` — minimal confirm + choice flow with fallback when elicitation is unsupported.
- `examples/advanced/ffmpeg-studio/transcode.sh` — uses elicitation (when available) to confirm overwriting an existing output; otherwise refuses to overwrite.

### Running via MCP Inspector
From the repo root, launch the example with the inspector’s stdio transport:
```bash
npx @modelcontextprotocol/inspector --transport stdio -- ./examples/run 08-elicitation
```
The `--` separator is required so the inspector doesn’t parse `./examples/run` as a flag.
