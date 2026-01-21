#!/usr/bin/env bash
# Test fixture: Tool that emits structured events WITHOUT .progress field.
# Tests that pattern matches extend timeout even when .progress is missing.
# Used by test/integration/test_progress_timeout.sh

set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

duration="$(mcp_args_int ".duration" --default 8)"

# Create a subprocess that emits JSON events to stderr
# These events match pattern but lack .progress field
emit_events() {
	local count="$1"
	for i in $(seq 1 "$count"); do
		# Emit step_start event - matches pattern but no .progress
		printf '{"type":"step_start","step":%d,"message":"Starting step %d"}\n' "$i" "$i" >&2
		sleep 1
		# Emit step_end event - matches pattern but no .progress
		printf '{"type":"step_end","step":%d,"message":"Completed step %d"}\n' "$i" "$i" >&2
	done
	echo '{"result":"success","steps_completed":'"$count"'}'
}

# Use mcp_run_with_progress with a pattern that matches our events
# The touch-on-pattern-match should keep the timeout extended
result=$(mcp_run_with_progress \
	--pattern '^\{.*"type"' \
	--extract json \
	--quiet \
	-- bash -c "$(declare -f emit_events); emit_events $duration")

mcp_result_success "$(mcp_json_obj message "Completed after ${duration}s" result "$result")"
