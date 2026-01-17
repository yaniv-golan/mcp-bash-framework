#!/usr/bin/env bash
set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck source=../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

# Parse arguments
# String (optional with default): name
name="$(mcp_args_get '.name' --default 'World')"
# Bool (optional): verbose flag
# verbose_flag="$(mcp_args_bool '.verbose' --default false)"
# Int (optional with bounds): limit
# limit="$(mcp_args_int '.limit' --default 10 --min 1 --max 100)"
# Path (validated against MCP roots): repo_path
# repo_path="$(mcp_require_path '.repoPath' --default-to-single-root)"
# Commands that emit non-JSON output should send it to stderr to keep stdout clean:
# git commit -m "msg" >&2   # example for git; avoid 2>&1 when stdout carries JSON
# Embed a file in the tool result (type:"resource"):
# mcp_result_text_with_resource '{"status":"done"}' --path /path/to/file --mime text/plain
# Multiple files: --path /file1 --mime text/plain --path /file2 --mime image/png

# Your tool logic here
# Example progress/logging (uncomment if needed)
# mcp_progress 10 "Starting work"
# mcp_log_info "tool" "args: ${MCP_TOOL_ARGS_JSON}"

# Return result (uses {success, result} envelope pattern)
mcp_result_success "$(mcp_json_obj message "Hello ${name}")"
