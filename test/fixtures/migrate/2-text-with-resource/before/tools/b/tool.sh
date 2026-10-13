#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
out=$(mcp_result_text_with_resource '{"a":1}' --path /tmp/x)
wrap() { mcp_result_text_with_resource "$@"; }
mcp_result_text_with_resource '{"a":1}' --path /tmp/x --uri "x --path y"
mcp_result_text_with_resource '{"a":1}' \
	--mime text/plain --uri 'a --path b' \
	--path /tmp/y
mcp_result_text_with_resource '{"a":1}' \
	--path /tmp/z
