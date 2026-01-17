#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

report_path="${MCPBASH_PROJECT_ROOT}/resources/report.txt"
mkdir -p "$(dirname "${report_path}")"
printf 'Embedded report' >"${report_path}"

mcp_result_text_with_resource \
	"$(mcp_json_obj message "See embedded report for details")" \
	--path "${report_path}" --mime text/plain
