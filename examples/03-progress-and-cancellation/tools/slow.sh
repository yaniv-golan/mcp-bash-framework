#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # sdk utilities live outside the example tree but are staged before execution
source "$(dirname "$0")/../../../sdk/tool-sdk.sh"
for pct in 10 50 90; do
	if mcp_is_cancelled; then
		exit 1
	fi
	mcp_progress "${pct}" "Working (${pct}%)"
	sleep 1
done
mcp_emit_text "Completed after progress updates"
