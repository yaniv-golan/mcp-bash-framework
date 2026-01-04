#!/usr/bin/env bash
set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck source=../../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

for pct in 10 50 90; do
	if mcp_is_cancelled; then
		mcp_fail -32001 "Cancelled"
	fi
	mcp_progress "${pct}" "Working (${pct}%)"
	sleep 1
done
mcp_result_success "$(mcp_json_obj message "Completed after progress updates")"
