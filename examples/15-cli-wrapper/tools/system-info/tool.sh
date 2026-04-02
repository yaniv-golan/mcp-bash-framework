#!/usr/bin/env bash
# CLI Wrapper Example: wraps system CLIs with proper PATH resolution and error handling.
#
# Key patterns demonstrated:
#   1. source tool-sdk.sh (always)
#   2. mcp_detect_cli for finding CLIs in restricted PATH
#   3. set -uo pipefail (no -e) for CLI error capture
#   4. mcp_result_success / mcp_result_error for MCP-compliant output

set -uo pipefail

# 1. Always source the SDK
# shellcheck disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

# 2. Source the CLI detection helper from our project's lib/
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${script_dir}/../../lib/cli-detect.sh"

# 3. Parse arguments using SDK helpers (not raw jq)
command_name="$(mcp_args_get '.command // empty')"
if [[ -z "${command_name}" ]]; then
	mcp_fail_invalid_args "Missing required argument: command"
fi

# 4. Detect CLIs — these may not be on PATH in MCP host environments
case "${command_name}" in
os)
	UNAME=$(mcp_detect_cli uname "Built-in on macOS/Linux") || mcp_fail -32603 "uname not found"
	output=$("${UNAME}" -a 2>&1) || {
		mcp_result_error "$(mcp_json_obj type "cli_error" message "uname failed: ${output}")"
		exit 0
	}
	mcp_result_success "$(mcp_json_obj os_info "${output}")"
	;;
uptime)
	UPTIME_CMD=$(mcp_detect_cli uptime "Built-in on macOS/Linux") || mcp_fail -32603 "uptime not found"
	output=$("${UPTIME_CMD}" 2>&1) || {
		mcp_result_error "$(mcp_json_obj type "cli_error" message "uptime failed: ${output}")"
		exit 0
	}
	mcp_result_success "$(mcp_json_obj uptime "${output}")"
	;;
disk)
	DF_CMD=$(mcp_detect_cli df "Built-in on macOS/Linux") || mcp_fail -32603 "df not found"
	output=$("${DF_CMD}" -h 2>&1) || {
		mcp_result_error "$(mcp_json_obj type "cli_error" message "df failed: ${output}")"
		exit 0
	}
	mcp_result_success "$(mcp_json_obj disk_usage "${output}")"
	;;
*)
	mcp_fail_invalid_args "Unknown command: ${command_name}. Use 'os', 'uptime', or 'disk'."
	;;
esac
