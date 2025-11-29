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
	printf 'mcp: SDK helpers not found (set MCP_SDK to your framework sdk/ path or keep this example inside the framework repo; expected %s/tool-sdk.sh)\n' "${MCP_SDK:-<unset>}" >&2
	exit 1
fi

# shellcheck source=../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK}/tool-sdk.sh"

live_progress="${MCPBASH_ENABLE_LIVE_PROGRESS:-false}"
for pct in 10 40 75 100; do
	if mcp_is_cancelled; then
		mcp_fail -32001 "Cancelled"
	fi
	mcp_progress "${pct}" "Manual registry progress demo (${pct}%)"
	sleep 0.5
done

mcp_emit_text "Manual registry tool finished (live_progress=${live_progress})"
