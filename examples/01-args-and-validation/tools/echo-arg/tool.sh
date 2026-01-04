#!/usr/bin/env bash
set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck source=../../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

# Use mcp_args_require for required arguments (fails with -32602 if missing)
value="$(mcp_args_require '.value')"

mcp_result_success "$(mcp_json_obj message "You sent: ${value}")"
