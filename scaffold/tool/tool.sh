#!/usr/bin/env bash
set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck source=../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

# Parse arguments
# String (required): name
name="$(mcp_args_require '.name')"
# Bool (optional): verbose flag
# verbose_flag="$(mcp_args_bool '.verbose' --default false)"
# Int (optional with bounds): limit
# limit="$(mcp_args_int '.limit' --default 10 --min 1 --max 100)"
# Path (validated against MCP roots): repo_path
# repo_path="$(mcp_require_path '.repoPath' --default-to-single-root)"

# Your tool logic here
# Example progress/logging (uncomment if needed)
# mcp_progress 10 "Starting work"
# mcp_log_info "tool" "args: ${MCP_TOOL_ARGS_JSON}"

# Return result
mcp_emit_json "$(mcp_json_obj message "Hello ${name}")"
