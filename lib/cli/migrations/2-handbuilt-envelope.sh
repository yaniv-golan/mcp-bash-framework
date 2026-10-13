#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-handbuilt-envelope
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SUMMARY="a hand-built result puts a {success, ...} envelope in structuredContent"
MIG_FIX='mcp_result_json JSON for results; mcp_fail --type TYPE "MESSAGE" for errors'
# A script that builds CallToolResult JSON itself (not through the SDK) with a
# "success" field next to structuredContent: in 2.0 the result's own data is
# the structured content, and an error is an isError result. A failure sent
# as {success: false} with isError false also hides the failure from the
# client. Found only in files that mention structuredContent.
mig_detect() {
	local file="$1"
	grep -q 'structuredContent' "${file}" 2>/dev/null || return 0
	mig_grep_regex '("success"|[^A-Za-z0-9_."]success)[[:space:]]*:[[:space:]]*(true|false)' "${file}"
}
