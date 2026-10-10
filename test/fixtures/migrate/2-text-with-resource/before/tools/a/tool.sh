#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_result_text_with_resource '{"m":1}' --path /etc/hosts --mime text/plain
