#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_emit_text "x"
mcp_emit_json '{}'
mcp_result_text_with_resource '{}' --path /f --mime text/plain
mcp_result_text "fine"
