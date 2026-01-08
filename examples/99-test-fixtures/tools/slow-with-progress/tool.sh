#!/usr/bin/env bash
# Test fixture: Tool that emits progress, runs longer than timeout.
# Used by test/integration/test_progress_timeout.sh

set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

duration="$(mcp_args_int ".duration" --default 10)"

for i in $(seq 1 "$duration"); do
	mcp_progress "$((i * 100 / duration))" "Working... step $i" "$duration"
	sleep 1
done

mcp_result_success "$(mcp_json_obj message "Completed after ${duration}s")"
