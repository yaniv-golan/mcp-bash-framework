#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

report_path="${MCPBASH_PROJECT_ROOT}/resources/report.txt"
mkdir -p "$(dirname "${report_path}")"
printf 'Embedded report' >"${report_path}"

if [ -n "${MCP_TOOL_RESOURCES_FILE:-}" ]; then
	printf '%s\ttext/plain\n' "${report_path}" >>"${MCP_TOOL_RESOURCES_FILE}"
fi

mcp_emit_json "$(mcp_json_obj message "See embedded report for details")"
