#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-result-success
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SUMMARY="mcp_result_success (wraps results in {success, result}) is removed in 2.0"
MIG_FIX='mcp_result_json JSON (no envelope; update outputSchema and UI reads of .result with it)'
MIG_SET=envelope
# Auto with a single argument (a positional max_text_bytes must become
# --max-text-bytes), not when the output is captured with $(...) (the caller
# post-processes the result's shape) or the call forwards "$@". Part of the "envelope" set: migrate rewrites a tool's
# result calls, outputSchema and UI reads together, or none of them.
mig_detect() {
	local line kind text
	mig_grep_word mcp_result_success "$1" | while IFS=$'\t' read -r line kind text; do
		if [ "$(mig_call_argc mcp_result_success "${text}")" = "1" ] && ! mig_call_is_opaque mcp_result_success "${text}"; then
			printf '%s\tauto\t%s\n' "${line}" "${text}"
		else
			printf '%s\tmanual\t%s\n' "${line}" "${text}"
		fi
	done
}
mig_apply() {
	local text
	text="$(mig_line "$1" "$2" | sed -E 's/(^|[^A-Za-z0-9_])mcp_result_success([^A-Za-z0-9_]|$)/\1mcp_result_json\2/')"
	mig_replace_line "$1" "$2" "${text}"
}
