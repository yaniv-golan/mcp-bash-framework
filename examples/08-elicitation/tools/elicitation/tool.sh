#!/usr/bin/env bash
set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck source=../../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

json_bin="${MCPBASH_JSON_TOOL_BIN:-}"
if [[ -z "${json_bin}" ]] || ! command -v "${json_bin}" >/dev/null 2>&1; then
	mcp_fail -32603 "JSON tooling unavailable for elicitation parsing"
fi

# 1. Simple confirmation (boolean)
confirm_resp="$(mcp_elicit_confirm "Do you want to proceed with the demo?")"
confirm_fields="$("${json_bin}" -r '[.action, (.content.confirmed // false)] | @tsv' <<<"${confirm_resp}")"
confirm_action="${confirm_fields%%$'\t'*}"

if [[ "${confirm_action}" != "accept" ]]; then
	mcp_result_success "$(mcp_json_obj message "Stopped: elicitation action=${confirm_action}")"
fi

# 2. Simple choice (untitled single-select)
mode_resp="$(mcp_elicit_choice "Pick a mode" "explore" "safe" "expert")"
mode_fields="$("${json_bin}" -r '[.action, (.content.choice // empty)] | @tsv' <<<"${mode_resp}")"
mode_action="${mode_fields%%$'\t'*}"
mode_choice="${mode_fields#*$'\t'}"

if [[ "${mode_action}" != "accept" ]]; then
	mcp_result_success "$(mcp_json_obj message "Stopped after mode choice: action=${mode_action}")"
fi

# 3. Titled choice (SEP-1330: oneOf with const+title)
quality_resp="$(mcp_elicit_titled_choice "Select output quality" \
	"high:High (1080p, larger file)" \
	"medium:Medium (720p, balanced)" \
	"low:Low (480p, smaller file)")"
quality_fields="$("${json_bin}" -r '[.action, (.content.choice // empty)] | @tsv' <<<"${quality_resp}")"
quality_action="${quality_fields%%$'\t'*}"
quality_choice="${quality_fields#*$'\t'}"

if [[ "${quality_action}" != "accept" ]]; then
	mcp_result_success "$(mcp_json_obj message "Stopped after quality choice: action=${quality_action}")"
fi

# 4. Multi-select (SEP-1330: array with enum items)
features_resp="$(mcp_elicit_multi_choice "Enable features (select multiple)" \
	"logging" "caching" "compression" "encryption")"
features_action="$("${json_bin}" -r '.action' <<<"${features_resp}")"
features_choices="$("${json_bin}" -r '(.content.choices // []) | join(", ")' <<<"${features_resp}")"

if [[ "${features_action}" != "accept" ]]; then
	mcp_result_success "$(mcp_json_obj message "Stopped after features selection: action=${features_action}")"
fi

mcp_result_success "$(
	mcp_json_obj \
		message "Elicitation complete" \
		mode "${mode_choice}" \
		quality "${quality_choice}" \
		features "${features_choices}"
)"
