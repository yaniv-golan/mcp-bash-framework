#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
mcp_fail -32602 "bad"
mcp_fail -32603 "boom" '{"a":1}'
mcp_fail -32001 "odd"
mcp_fail "$code" "var"
mcp_fail "one argument"
mcp_fail --type internal "new form"
X="$(command -v jq)" || mcp_fail -32603 "jq missing"
mcp_fail "${msg}" --hint "try again"
mcp_fail -- "--type"
mcp_fail 404 "gone"
