#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_result_success "$(mcp_json_obj a 1)"
wrap() {
	mcp_result_success "$@"
}
out="$(mcp_result_success '{}')"
