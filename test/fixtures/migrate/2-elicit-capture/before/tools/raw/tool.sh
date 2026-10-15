#!/usr/bin/env bash
source "${MCP_SDK:?}/tool-sdk.sh"
resp="$(mcp_elicit "Sure?" '{"type":"object","properties":{"ok":{"type":"boolean"}}}')" || true
url="$(mcp_elicit_url_raw "Sign in" "https://example.com")" || true
