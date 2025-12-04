#!/usr/bin/env bash
set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck source=../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

# Parse arguments
name="$(mcp_args_get '.name // "World"')"

# Your tool logic here

# Return result
mcp_emit_json "$(mcp_json_obj message "Hello ${name}")"
