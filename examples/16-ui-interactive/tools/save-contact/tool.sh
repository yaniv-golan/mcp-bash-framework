#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

# This runs when the form's app.callServerTool({ name: "save-contact", ... }) is
# proxied by the host to the server. Seeing this result in the UI proves the
# UI -> host -> server round-trip works.
name="$(mcp_args_require '.name')"
email="$(mcp_args_get '.email' '')"
message="$(mcp_args_get '.message' '')"

mcp_result_success "$(mcp_json_obj \
	saved true \
	name "${name}" \
	email "${email}" \
	message "${message}" \
	note "Saved by the save-contact tool — the form's callServerTool round-trip worked.")"
