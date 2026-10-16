#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_elicit_confirm "Delete 40 files?"
if mcp_elicit_confirm "Sure?"; then :; fi
mcp_elicit_string -v name "Name?" || exit 0
! mcp_elicit_confirm "Not this?"
mcp_elicit_confirm "Also?" && echo yes
# mcp_elicit_confirm "in a comment"
while mcp_elicit_confirm "Again?"; do :; done
elif_case() { if false; then :; elif mcp_elicit_confirm "x"; then :; fi; }
echo "mcp_elicit_confirm in a string"
	mcp_elicit_choice -v mode "Mode?" a b
