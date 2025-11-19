#!/usr/bin/env bash
# Manual registration script; invoked when executable (manual overrides).

set -euo pipefail

# Use mcp_register_tool/resource/prompt helpers (manual overrides).
# Example:
# mcp_register_tool '{
#   "name": "manual-hello",
#   "description": "Manual tool example",
#   "path": "tools/manual/hello.sh",
#   "arguments": {"type":"object","properties":{}}
# }'

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	exit 0
fi
return 0
