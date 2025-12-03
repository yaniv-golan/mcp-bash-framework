#!/usr/bin/env bash
set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck source=../../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

value="$(mcp_args_get '.value')"
if [ -z "${value}" ]; then
	mcp_fail_invalid_args "Missing 'value' argument"
fi

mcp_emit_json "$(mcp_json_obj message "You sent: ${value}")"
