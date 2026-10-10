#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_result_with_ui "" "Ready" '{"n":1}'
mcp_result_with_ui_data "ui://x/y" "Rows" "$rows"
