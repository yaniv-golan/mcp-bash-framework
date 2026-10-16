#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
resp=$(mcp_elicit_string "Name?")
r2="$( mcp_elicit_choice "Mode?" a b )"
r3=`mcp_elicit_titled_choice "Q?" "h:High"`
ask() { local r; r=$(mcp_elicit_multi_choice "F?" x y) || true; printf '%s' "$r"; }
if out="$(mcp_elicit_confirm "Sure?")"; then :; fi
action="$(mcp_elicit_confirm "Sure?" | jq -r .action)"
mcp_elicit_url "Sign in" "https://example.com" | jq -r .action
mcp_elicit_titled_multi_choice "M?" "a:A" | tee /tmp/answer >/dev/null
# 2.0 forms, never findings:
if mcp_elicit_confirm "Fine?"; then :; fi
mcp_elicit_string -v name "Name?" || true
echo "not $(mcp_elicit_raw_thing)"
