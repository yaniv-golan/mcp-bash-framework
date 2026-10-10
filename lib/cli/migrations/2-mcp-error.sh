#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-mcp-error
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SUMMARY="mcp_error is removed in 2.0 (mcp_fail --type ends the tool; mcp_error did not)"
MIG_FIX='mcp_fail --type TYPE "MESSAGE" [--hint TEXT] [--data JSON]'
# Auto only when the next statement is an exit: mcp_fail ends the tool, so
# code after an mcp_error, or a caller continuing after a "return", would
# silently stop running.
mig_detect() {
	local file="$1" line kind text next
	mig_grep_word mcp_error "${file}" | while IFS=$'\t' read -r line kind text; do
		next="$(awk -v n="${line}" 'NR > n && $0 !~ /^[[:space:]]*(#.*)?$/ { print; exit }' "${file}")"
		case "${next}" in
		*[[:space:]]exit | *[[:space:]]exit[[:space:]]* | exit | exit[[:space:]]*)
			printf '%s\tauto\t%s\n' "${line}" "${text}"
			;;
		*) printf '%s\tmanual\t%s (no exit after it: code below still runs today)\n' "${line}" "${text}" ;;
		esac
	done
}
mig_apply() {
	local text
	text="$(mig_line "$1" "$2" | sed -E 's/(^|[^A-Za-z0-9_])mcp_error([^A-Za-z0-9_]|$)/\1mcp_fail --type\2/')"
	mig_replace_line "$1" "$2" "${text}"
}
