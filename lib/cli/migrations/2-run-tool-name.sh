#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-run-tool-name
MIG_API=2
MIG_KIND=advisory
MIG_SCOPE="project-sh"
MIG_VALIDATE=0
MIG_SUMMARY="tool results no longer carry a top-level \"name\" in 2.0 (it wasn't in the MCP schema)"
MIG_FIX='select the result some other way, e.g. select(has("content")); run-tool prints one result per call'
# Advisory only (listed, never pending): a script that runs `mcp-bash
# run-tool` and selects its output by .name. Found only in files that
# mention run-tool, so jq over other data can be listed too.
mig_detect() {
	local file="$1"
	grep -q 'run-tool' "${file}" 2>/dev/null || return 0
	mig_grep_regex 'select[(][[:space:]]*[.]name[[:space:]]*==' "${file}"
}
