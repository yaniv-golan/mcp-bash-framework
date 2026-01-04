#!/usr/bin/env bash
set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck source=../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

live_progress="${MCPBASH_ENABLE_LIVE_PROGRESS:-false}"
for pct in 10 40 75 100; do
	if mcp_is_cancelled; then
		mcp_fail -32001 "Cancelled"
	fi
	mcp_progress "${pct}" "Manual registry progress demo (${pct}%)"
	sleep 0.5
done

mcp_result_success "$(mcp_json_obj message "Manual registry tool finished (live_progress=${live_progress})")"
