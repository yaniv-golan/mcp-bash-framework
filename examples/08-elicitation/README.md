# 08-elicitation

**What you'll learn**
- How tools invoke the elicitation flow using SDK helpers
- All four elicitation patterns: confirm, choice, titled choice, multi-select
- The 2.0 calling style: call the helper directly (in an `if`), get the answer with `-v VAR`, and read why it wasn't a yes from `MCP_ELICIT_ACTION` (`decline`, `cancel`, `unavailable`)

**Prereqs**
- Bash 3.2+
- jq or gojq (required for elicitation helpers)

**Run**
```
./examples/run 08-elicitation
```

**What it does**
1. Asks for a confirmation (boolean yes/no)
2. Asks you to pick a mode from a simple list (untitled single-select)
3. Asks you to pick a quality with display labels (titled single-select, SEP-1330)
4. Asks you to enable features (multi-select checkboxes, SEP-1330)
5. Returns a summary of all selections

**SDK Helpers**

| Helper | Mode | Use Case |
|--------|------|----------|
| `mcp_elicit_confirm` | form | Yes/no confirmation |
| `mcp_elicit_choice` | form | Radio buttons (simple values) |
| `mcp_elicit_titled_choice` | form | Radio buttons with display labels (SEP-1330) |
| `mcp_elicit_multi_choice` | form | Checkboxes (SEP-1330) |
| `mcp_elicit_titled_multi_choice` | form | Checkboxes with display labels (SEP-1330) |
| `mcp_elicit_url` | url | Open browser for OAuth/payments (SEP-1036) |

**Example titled choice:**
```bash
if mcp_elicit_titled_choice -v quality "Select quality" \
    "high:High (1080p, larger file)" \
    "low:Low (480p, smaller file)"; then
    echo "picked ${quality}" >&2      # the value: high or low
else
    echo "no answer: ${MCP_ELICIT_ACTION}" >&2
fi
```

Exit 0 means the user accepted; exit 1 anything else. Under `set -e`, call the helpers in an `if` or before `||`. Add `--arg NAME` to take the answer from the tool's argument `NAME` when the call has it (for clients that can't ask, and for scripted runs).

**Example URL mode (SEP-1036):**
```bash
# Secure out-of-band interaction (opens browser, data never passes through client)
if mcp_elicit_url "Complete OAuth authorization" "https://auth.example.com/authorize?..."; then
    echo "User completed the flow in browser" >&2
fi
```

**Success criteria**
- `tools/list` shows `example-elicitation`
- Calling `example-elicitation` walks through all four elicitation types
- The final result's `structuredContent` holds `mode`, `quality` and `features` (e.g. `"features": "logging, caching"`)
