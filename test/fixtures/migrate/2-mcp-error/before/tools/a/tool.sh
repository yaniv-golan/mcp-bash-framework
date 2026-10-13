#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_error not_found "gone" --hint "list"
exit 0
mcp_error internal "then more"
echo cleanup
mcp_error not_found "multi" \
	--hint "line two"
exit 0
helper() {
	mcp_error invalid_args "bad"
	return 1
}
