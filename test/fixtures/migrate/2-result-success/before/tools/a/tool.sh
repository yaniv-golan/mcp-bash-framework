#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_result_success "$(mcp_json_obj a 1)"
