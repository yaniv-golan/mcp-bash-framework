#!/usr/bin/env bash
# MCP Bash UI SDK
# Helpers for tool authors to work with MCP Apps UI resources (SEP-1865)
#
# Usage in tools:
#   source "${MCP_SDK}/tool-sdk.sh"
#   # ui-sdk.sh is automatically sourced by tool-sdk.sh
#
# Functions:
#   mcp_client_supports_ui       - Check if client supports UI extension
#   mcp_result_with_ui           - Emit result with UI resource reference
#   mcp_result_with_ui_data      - Emit result with UI resource + structured data
#   mcp_ui_form                  - Generate dynamic form HTML
#   mcp_ui_table                 - Generate dynamic table HTML

set -euo pipefail

# --- Capability checks ---

# Check if current client supports UI extension
# Returns: 0 if supported, 1 if not
# Usage: if mcp_client_supports_ui; then ... fi
mcp_client_supports_ui() {
	# Check in-memory flag first (main process)
	if [ "${MCPBASH_CLIENT_SUPPORTS_UI:-0}" = "1" ]; then
		return 0
	fi

	# Check state file (subprocess/tool context)
	local flag_path="${MCPBASH_STATE_DIR:-}/extensions.ui.support"
	if [ -f "${flag_path}" ]; then
		local flag
		flag="$(cat "${flag_path}" 2>/dev/null || true)"
		[ "${flag}" = "1" ] && return 0
	fi

	return 1
}

# --- Result helpers ---

# Emit tool result with structured data for UI rendering
# Usage: mcp_result_with_ui <resource_uri> <text_fallback> [structured_data]
#
# NOTE: Per MCP Apps spec (2026-01-26), the UI resource is declared in the tool
# DEFINITION (_meta.ui in tool.meta.json), not in tool results. This function
# returns structured data that the UI template will receive via notification.
# The resource_uri parameter is kept for backward compatibility but is ignored.
#
# Arguments:
#   resource_uri    - DEPRECATED: UI resource is in tool.meta.json, not results
#   text_fallback   - Plain text for clients without UI support
#   structured_data - Optional JSON data for UI (default: null)
#
# Example:
#   mcp_result_with_ui "" "Dashboard ready" '{"items": 42}'
mcp_result_with_ui() {
	local resource_uri="$1" # Ignored per spec - UI declared in tool definition
	local text_fallback="$2"
	local structured_data="${3:-null}"

	# If client doesn't support UI, return text-only result
	if ! mcp_client_supports_ui; then
		mcp_result_success "${text_fallback}"
		return
	fi

	# Return result with structured data (host knows UI from tool definition)
	"${MCPBASH_JSON_TOOL_BIN}" -n \
		--arg text "${text_fallback}" \
		--argjson data "${structured_data}" \
		'{
			content: [{type: "text", text: $text}],
			structuredContent: (if $data != null then $data else null end),
			isError: false
		}'
}

# Emit tool result with structured data for UI rendering
# Usage: mcp_result_with_ui_data <resource_uri> <text_fallback> <ui_data>
#
# NOTE: Per MCP Apps spec (2026-01-26), the UI resource is declared in the tool
# DEFINITION (_meta.ui in tool.meta.json), not in tool results. This function
# returns structured data that the UI template will receive via notification.
# The resource_uri parameter is kept for backward compatibility but is ignored.
#
# Arguments:
#   resource_uri  - DEPRECATED: UI resource is in tool.meta.json, not results
#   text_fallback - Plain text for clients without UI support
#   ui_data       - JSON data for the UI (required)
#
# Example:
#   mcp_result_with_ui_data "" "Query returned 10 rows" "$json_results"
mcp_result_with_ui_data() {
	local resource_uri="$1" # Ignored per spec - UI declared in tool definition
	local text_fallback="$2"
	local ui_data="$3"

	if ! mcp_client_supports_ui; then
		mcp_result_success "${text_fallback}"
		return
	fi

	# Return result with structured data (host knows UI from tool definition)
	"${MCPBASH_JSON_TOOL_BIN}" -n \
		--arg text "${text_fallback}" \
		--argjson data "${ui_data}" \
		'{
			content: [{type: "text", text: $text}],
			structuredContent: $data,
			isError: false
		}'
}

# --- Dynamic UI generation ---

# Generate a simple form UI dynamically
# Usage: mcp_ui_form --title "Title" --field "name:type:options" --submit-tool "tool"
#
# Options:
#   --title        - Form title
#   --field        - Field definition (name:type[:options])
#                    Types: text, email, number, date, textarea, select, checkbox
#                    For select: name:select:opt1,opt2,opt3
#   --submit-tool  - Tool to call on form submit
#
# Example:
#   mcp_ui_form \
#     --title "Log Entry" \
#     --field "type:select:meeting,call,email" \
#     --field "notes:textarea" \
#     --submit-tool "log-interaction"
mcp_ui_form() {
	local title=""
	local fields=()
	local submit_tool=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--title)
			title="$2"
			shift 2
			;;
		--field)
			fields+=("$2")
			shift 2
			;;
		--submit-tool)
			submit_tool="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	# Build fields JSON array
	local fields_json="[]"
	for field in "${fields[@]}"; do
		IFS=':' read -r name type options <<<"${field}"
		local field_obj
		field_obj="$("${MCPBASH_JSON_TOOL_BIN}" -n \
			--arg name "${name}" \
			--arg type "${type:-text}" \
			--arg options "${options:-}" \
			'{
				name: $name,
				type: $type,
				label: ($name | gsub("[-_]"; " ") | split(" ") | map(. | split("") | .[0:1] | map(ascii_upcase) | . + .[1:] | join("")) | join(" ")),
				options: (if $options != "" then ($options | split(",")) else null end)
			}')"
		fields_json="$("${MCPBASH_JSON_TOOL_BIN}" --argjson f "${field_obj}" '. += [$f]' <<<"${fields_json}")"
	done

	# Generate template config and call template generator
	local config
	config="$("${MCPBASH_JSON_TOOL_BIN}" -n \
		--arg title "${title}" \
		--argjson fields "${fields_json}" \
		--arg submitTool "${submit_tool}" \
		'{title: $title, fields: $fields, submitTool: $submitTool}')"

	# Check if template generator is available
	if declare -F mcp_ui_template_form >/dev/null 2>&1; then
		mcp_ui_template_form "${config}"
	else
		printf '%s\n' "Error: mcp_ui_template_form not available" >&2
		return 1
	fi
}

# Pipe JSON data to table UI
# Usage: echo "$data" | mcp_ui_table --columns "col1,col2,col3" [--title "Title"]
#
# Options:
#   --columns  - Comma-separated column names
#   --title    - Optional table title
#
# Example:
#   echo '[{"name":"John","age":30}]' | mcp_ui_table --columns "name,age"
mcp_ui_table() {
	local columns=""
	local title="Data"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--columns)
			columns="$2"
			shift 2
			;;
		--title)
			title="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	# Note: stdin data is consumed by the template when rendering
	# Build columns JSON array
	local columns_json="[]"
	IFS=',' read -ra cols <<<"${columns}"
	for col in "${cols[@]}"; do
		columns_json="$("${MCPBASH_JSON_TOOL_BIN}" --arg c "${col}" \
			'. += [{key: $c, label: $c, sortable: true}]' <<<"${columns_json}")"
	done

	# Generate template config
	local config
	config="$("${MCPBASH_JSON_TOOL_BIN}" -n \
		--arg title "${title}" \
		--argjson columns "${columns_json}" \
		'{title: $title, columns: $columns}')"

	# Check if template generator is available
	if declare -F mcp_ui_template_data_table >/dev/null 2>&1; then
		mcp_ui_template_data_table "${config}"
	else
		printf '%s\n' "Error: mcp_ui_template_data_table not available" >&2
		return 1
	fi
}

# --- Metadata reference helper ---

# Build tool metadata with UI reference
# Usage: mcp_tool_meta_with_ui <resource_uri> [visibility]
#
# Arguments:
#   resource_uri - UI resource URI
#   visibility   - Optional array: "model", "app", or "model,app" (default: "model,app")
#
# Example:
#   # In tool.meta.json, use this output for _meta field
#   mcp_tool_meta_with_ui "ui://myserver/query-builder"
mcp_tool_meta_with_ui() {
	local resource_uri="$1"
	local visibility="${2:-model,app}"

	# Parse visibility into JSON array
	local visibility_json
	visibility_json="$("${MCPBASH_JSON_TOOL_BIN}" -n --arg v "${visibility}" \
		'$v | split(",") | map(gsub("^\\s+|\\s+$"; ""))')"

	"${MCPBASH_JSON_TOOL_BIN}" -n \
		--arg uri "${resource_uri}" \
		--argjson vis "${visibility_json}" \
		'{
			ui: {
				resourceUri: $uri,
				visibility: $vis
			}
		}'
}
