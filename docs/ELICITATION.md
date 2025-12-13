# Elicitation Support in mcp-bash

Elicitation lets a tool pause execution, ask the MCP client for user input, and continue once a response arrives. It is supported when the client advertises `capabilities.elicitation` during `initialize`.

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

The SDK exposes helpers in `sdk/tool-sdk.sh`:

### Form Mode (in-band)
- `mcp_elicit <message> <schema_json> [timeout_secs] [mode]` — core function
- `mcp_elicit_string <message> [field_name]` — free-text input
- `mcp_elicit_confirm <message>` — yes/no boolean
- `mcp_elicit_choice <message> opt1 opt2 ...` — radio buttons (single select)
- `mcp_elicit_titled_choice <message> "val1:Label 1" "val2:Label 2"` — radio buttons with display labels (SEP-1330)
- `mcp_elicit_multi_choice <message> opt1 opt2 ...` — checkboxes (multi-select, SEP-1330)
- `mcp_elicit_titled_multi_choice <message> "val1:Label 1" ...` — checkboxes with labels

### URL Mode (out-of-band, SEP-1036)
- `mcp_elicit_url <message> <url> [timeout_secs]` — opens browser for OAuth/payments

```bash
# Example: OAuth authorization
resp="$(mcp_elicit_url "Authorize with GitHub" "https://github.com/login/oauth/authorize?...")"
if [ "$(echo "$resp" | jq -r '.action')" = "accept" ]; then
    echo "User completed authorization"
fi
```

## Environment Variables

Set for tools:
- `MCP_ELICIT_SUPPORTED` – `"1"` when the client supports elicitation, `"0"` otherwise.
- `MCP_ELICIT_REQUEST_FILE` – path to write a request (JSON: `{"message": "...", "schema": {...}, "mode": "form"}`).
- `MCP_ELICIT_RESPONSE_FILE` – where the normalized response appears.

The SDK handles writing/reading these files, timeouts, and cancellation. Tools should branch on `.action` (`accept`, `decline`, `cancel`, `error`) and only use `.content` when `action=accept`.

## Examples
- `examples/08-elicitation` — minimal confirm + choice flow with fallback when elicitation is unsupported.
- `examples/advanced/ffmpeg-studio/transcode.sh` — uses elicitation (when available) to confirm overwriting an existing output; otherwise refuses to overwrite.

### Running via MCP Inspector
From the repo root, launch the example with the inspector’s stdio transport:
```bash
npx @modelcontextprotocol/inspector --transport stdio -- ./examples/run 08-elicitation
```
The `--` separator is required so the inspector doesn’t parse `./examples/run` as a flag.
