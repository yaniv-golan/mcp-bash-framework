#!/usr/bin/env bash
set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck source=../../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

confirm_resp="$(mcp_elicit_confirm "Do you want to proceed with the demo?")"
confirm_action="$(printf '%s' "${confirm_resp}" | jq -r '.action')"

if [ "${confirm_action}" != "accept" ]; then
	mcp_emit_text "Stopped: elicitation action=${confirm_action}"
	exit 0
fi

mode_resp="$(mcp_elicit_choice "Pick a mode" "explore" "safe" "expert")"
mode_action="$(printf '%s' "${mode_resp}" | jq -r '.action')"

if [ "${mode_action}" != "accept" ]; then
	mcp_emit_text "Stopped after confirm: elicitation action=${mode_action}"
	exit 0
fi

choice="$(printf '%s' "${mode_resp}" | jq -r '.content.choice')"
mcp_emit_text "Elicitation complete: mode=${choice}"
