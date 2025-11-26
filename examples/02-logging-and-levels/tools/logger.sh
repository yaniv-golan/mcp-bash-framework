#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${MCP_SDK:-}" ] || [ ! -f "${MCP_SDK}/tool-sdk.sh" ]; then
	if fallback_sdk="$(cd "${script_dir}/../../../sdk" 2>/dev/null && pwd)"; then
		if [ -f "${fallback_sdk}/tool-sdk.sh" ]; then
			MCP_SDK="${fallback_sdk}"
		fi
	fi
fi

if [ -z "${MCP_SDK:-}" ] || [ ! -f "${MCP_SDK}/tool-sdk.sh" ]; then
	printf 'mcp: SDK helpers not found (expected %s/tool-sdk.sh)\n' "${MCP_SDK:-<unset>}" >&2
	exit 1
fi

# shellcheck source=../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK}/tool-sdk.sh"
mcp_log_info "example.logger" "about to work"

json_tool="${MCPBASH_JSON_TOOL_BIN:-}"
if [ -z "${json_tool}" ] || ! command -v "${json_tool}" >/dev/null 2>&1; then
	json_tool=""
fi

emit_message_json() {
	local message="$1"
	if [ -n "${json_tool}" ]; then
		mcp_emit_json "$("${json_tool}" -n --arg message "${message}" '{message:$message}')" || mcp_emit_text "${message}"
	else
		mcp_emit_text "${message}"
	fi
}

emit_message_json "Check your logging notifications"
