#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_error not_found "gone" --hint "list"
exit 0
mcp_error internal "then more"
echo cleanup
