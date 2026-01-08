#!/usr/bin/env bash
# Test fixture: Tool that does NOT emit progress, expected to timeout.
# Used by test/integration/test_progress_timeout.sh

set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

duration="$(mcp_args_int ".duration" --default 10)"

# Just sleep without emitting any progress
sleep "$duration"

mcp_result_success "$(mcp_json_obj message "Completed after ${duration}s")"
