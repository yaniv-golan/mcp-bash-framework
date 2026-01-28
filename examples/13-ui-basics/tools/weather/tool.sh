#!/usr/bin/env bash
set -euo pipefail

# Source SDK
# shellcheck disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

# Parse arguments
location="$(mcp_args_get '.location' 2>/dev/null || echo 'New York')"
[ -z "${location}" ] && location="New York"

# Simulated weather data
temperature=$((60 + RANDOM % 40))
conditions=("Sunny" "Cloudy" "Rainy" "Partly Cloudy")
condition="${conditions[$((RANDOM % 4))]}"
humidity=$((30 + RANDOM % 50))

# Build result JSON
result=$(mcp_json_obj \
	location "${location}" \
	temperature "${temperature}" \
	condition "${condition}" \
	humidity "${humidity}" \
	unit "F")

# Output result (UI resource is declared in tool.meta.json, not needed in result)
result_string=$(printf '%s' "${result}" | jq -c '.' | jq -Rs '.')
cat <<EOF
{
  "content": [{"type": "text", "text": ${result_string}}],
  "structuredContent": ${result},
  "isError": false
}
EOF
