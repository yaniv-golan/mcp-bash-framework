#!/usr/bin/env bash
# Test fixture: Tool with timeoutHint configured.
# Used to test that timeout error messages include the hint.

set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

duration="$(mcp_args_int ".duration" --default 10)"

# Just sleep without emitting any progress (will timeout)
sleep "$duration"

mcp_result_success "$(mcp_json_obj message "Completed after ${duration}s")"
