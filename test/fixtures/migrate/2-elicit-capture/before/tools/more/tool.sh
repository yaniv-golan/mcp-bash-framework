#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
while read -r line; do :; done < <(mcp_elicit_multi_choice "F?" a b)
mcp_elicit_confirm "Sure?" >answer.json
mcp_elicit_confirm "Sure?" > "${tmp}"
resp="$(
	mcp_elicit_confirm "Across lines?"
)"
r1="$(FOO=1 mcp_elicit_confirm "Prefixed?")"
r2=$(command mcp_elicit_string "Command?")
LANG=C mcp_elicit_choice "Piped?" a b | jq -r .action
# 2.0 forms and other non-findings:
if mcp_elicit_choice -v fmt "Format (json|csv)?" json csv; then :; fi
if mcp_elicit_confirm "Quiet?" >/dev/null 2>&1; then :; fi
mcp_elicit_string -v n "Log it?" 2>err.log || true
mcp_elicit_string -v n "Name? 'a|b'" || echo "no | pipe here"
