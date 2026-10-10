#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
resp="$(mcp_elicit_confirm "Sure?")" || true
action="$(jq -r .action <<<"$resp")"
