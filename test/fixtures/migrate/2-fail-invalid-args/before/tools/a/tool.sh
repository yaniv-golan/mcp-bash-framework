#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
# mcp_fail_invalid_args in a comment is ignored
[ -n "$x" ] || mcp_fail_invalid_args "x is required"
mcp_fail_invalid_args_extra=1
