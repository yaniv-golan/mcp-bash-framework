#!/usr/bin/env bash
set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck source=../../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

# The mcp_elicit_* helpers exit 0 when the user accepts and 1 otherwise, with
# the reason in MCP_ELICIT_ACTION (decline, cancel or unavailable: the client
# can't ask, or the question timed out). Call them in an if (or before ||):
# under set -e, a bare call would end the tool on any answer but yes. -v VAR
# puts the answer in VAR.
mode_choice="" quality_choice="" features_json=""

# 1. Simple confirmation (boolean)
if ! mcp_elicit_confirm "Do you want to proceed with the demo?"; then
	mcp_result_json "$(mcp_json_obj message "Stopped: elicitation action=${MCP_ELICIT_ACTION}")"
	exit 0
fi

# 2. Simple choice (untitled single-select)
if ! mcp_elicit_choice -v mode_choice "Pick a mode" "explore" "safe" "expert"; then
	mcp_result_json "$(mcp_json_obj message "Stopped after mode choice: action=${MCP_ELICIT_ACTION}")"
	exit 0
fi

# 3. Titled choice (SEP-1330: oneOf with const+title); the answer is the value.
if ! mcp_elicit_titled_choice -v quality_choice "Select output quality" \
	"high:High (1080p, larger file)" \
	"medium:Medium (720p, balanced)" \
	"low:Low (480p, smaller file)"; then
	mcp_result_json "$(mcp_json_obj message "Stopped after quality choice: action=${MCP_ELICIT_ACTION}")"
	exit 0
fi

# 4. Multi-select (SEP-1330: array with enum items); the answer is a JSON array.
if ! mcp_elicit_multi_choice -v features_json "Enable features (select multiple)" \
	"logging" "caching" "compression" "encryption"; then
	mcp_result_json "$(mcp_json_obj message "Stopped after features selection: action=${MCP_ELICIT_ACTION}")"
	exit 0
fi
features_choices="$("${MCPBASH_JSON_TOOL_BIN:-jq}" -r 'join(", ")' <<<"${features_json}")"

mcp_result_json "$(
	mcp_json_obj \
		message "Elicitation complete" \
		mode "${mode_choice}" \
		quality "${quality_choice}" \
		features "${features_choices}"
)"
