#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-fail-invalid-args
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SUMMARY="mcp_fail_invalid_args is removed in 2.0"
MIG_FIX='mcp_fail --type invalid_args "MESSAGE" [--data JSON]'
# Auto only with a single message argument (a data argument must become --data).
mig_detect() {
	local line kind text
	mig_grep_word mcp_fail_invalid_args "$1" | while IFS=$'\t' read -r line kind text; do
		if [ "$(mig_call_argc mcp_fail_invalid_args "${text}")" = "1" ] && ! mig_call_is_opaque mcp_fail_invalid_args "${text}"; then
			printf '%s\tauto\t%s\n' "${line}" "${text}"
		else
			printf '%s\tmanual\t%s\n' "${line}" "${text}"
		fi
	done
}
mig_apply() {
	local text
	text="$(mig_line "$1" "$2" | sed -E 's/(^|[^A-Za-z0-9_])mcp_fail_invalid_args([^A-Za-z0-9_]|$)/\1mcp_fail --type invalid_args\2/')"
	mig_replace_line "$1" "$2" "${text}"
}
