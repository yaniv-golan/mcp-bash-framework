#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-elicit-capture
MIG_API=2
MIG_KIND=manual
MIG_SILENT=1
MIG_SCOPE="project-sh"
MIG_SUMMARY='the mcp_elicit_* question helpers print nothing in 2.0: capturing them with $(...) and parsing .action no longer works'
# shellcheck disable=SC2016  # The fix text shows literal shell code.
MIG_FIX='call them directly: "if mcp_elicit_confirm MESSAGE; then" (or "mcp_elicit_string -v VAR MESSAGE"); the reason for a no is in $MCP_ELICIT_ACTION (decline, cancel, unavailable). For the raw JSON, use mcp_elicit'
# Captured with $(...) or backticks, or piped into another command (jq):
# all 1.x ways of reading the JSON these helpers no longer print. The raw
# mcp_elicit and mcp_elicit_url_raw still print it.
mig_detect() {
	local h='mcp_elicit_(string|confirm|choice|titled_choice|multi_choice|titled_multi_choice|url)'
	mig_grep_regex "([\$][(]|\`)[[:space:]]*${h}([[:space:]]|[)\`]|\$)|(^|[^A-Za-z0-9_])${h}([[:space:]][^|]*)?[|]([^|]|\$)" "$1"
}
