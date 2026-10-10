# 08-elicitation

**What you'll learn**
- How tools invoke the elicitation flow using SDK helpers
- All four elicitation patterns: confirm, choice, titled choice, multi-select
- Normalized response handling (`action` + `content`) and fallbacks when the client doesn't support elicitation

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
mcp_elicit_titled_choice "Select quality" \
    "high:High (1080p, larger file)" \
    "low:Low (480p, smaller file)"
```

**Example URL mode (SEP-1036):**
```bash
# Secure out-of-band interaction (opens browser, data never passes through client)
resp="$(mcp_elicit_url "Complete OAuth authorization" "https://auth.example.com/authorize?...")" || true
if [ "$(echo "$resp" | jq -r '.action')" = "accept" ]; then
    echo "User completed the flow in browser" >&2
fi
```

**Success criteria**
- `tools/list` shows `example-elicitation`
- Calling `example-elicitation` walks through all four elicitation types
- The final result's `structuredContent` holds `mode`, `quality` and `features` (e.g. `"features": "logging, caching"`)
