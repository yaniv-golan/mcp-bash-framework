#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${MCP_SDK:-}" ] || [ ! -f "${MCP_SDK}/tool-sdk.sh" ]; then
	if fallback_sdk="$(cd "${script_dir}/../../sdk" 2>/dev/null && pwd)"; then
		if [ -f "${fallback_sdk}/tool-sdk.sh" ]; then
			MCP_SDK="${fallback_sdk}"
		fi
	fi
fi

if [ -z "${MCP_SDK:-}" ] || [ ! -f "${MCP_SDK}/tool-sdk.sh" ]; then
	printf 'mcp: SDK helpers not found (expected %s/tool-sdk.sh)\n' "${MCP_SDK:-<unset>}" >&2
	exit 1
fi

# shellcheck source=../../sdk/tool-sdk.sh disable=SC1091
. "${MCP_SDK}/tool-sdk.sh"

json_escape() {
	local value="$1"
	if command -v jq >/dev/null 2>&1; then
		jq -n --arg val "$value" '$val'
		return 0
	fi
	local escaped="${value//\\/\\\\}"
	escaped="${escaped//\"/\\\"}"
	escaped="${escaped//$'\n'/\\n}"
	escaped="${escaped//$'\r'/\\r}"
	printf '"%s"' "${escaped}"
}

name="$(mcp_args_get '.name // empty' 2>/dev/null || true)"
if [ -z "${name}" ]; then
	name="there"
fi

# Uncomment to demonstrate progress and logging helpers.
# mcp_progress 25 "Preparing response"
# mcp_log info "__NAME__" '{"type":"text","text":"Responding to completion"}'

message_json="$(json_escape "Hello ${name}")"
mcp_emit_json "{\"message\":${message_json}}"
