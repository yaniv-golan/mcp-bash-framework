#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-emit-helpers
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SUMMARY="mcp_emit_text and mcp_emit_json are removed in 2.0"
MIG_FIX='mcp_result_text TEXT or mcp_result_json JSON'
mig_detect() {
	mig_grep_regex '(^|[^A-Za-z0-9_])(mcp_emit_text|mcp_emit_json)([^A-Za-z0-9_]|$)' "$1"
}
