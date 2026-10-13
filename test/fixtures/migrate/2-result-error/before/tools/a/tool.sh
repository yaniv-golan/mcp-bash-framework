#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_result_error '{"type":"x","message":"y"}'
fail_with_warning() {
	local err="$1"
	shift
	mcp_result_error "$err" "$@"
}
