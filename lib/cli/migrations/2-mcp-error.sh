#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-mcp-error
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SUMMARY="mcp_error is removed in 2.0 (mcp_fail --type ends the tool; mcp_error did not)"
MIG_FIX='mcp_fail --type TYPE "MESSAGE" [--hint TEXT]'
# Auto only when the next statement already ends the tool (exit/return):
# mcp_fail exits, so code after an mcp_error would otherwise stop running.
mig_detect() {
	local file="$1" line kind text next
	mig_grep_word mcp_error "${file}" | while IFS=$'\t' read -r line kind text; do
		next="$(awk -v n="${line}" 'NR > n && $0 !~ /^[[:space:]]*(#.*)?$/ { print; exit }' "${file}")"
		case "${next}" in
		*[[:space:]]exit | *[[:space:]]exit[[:space:]]* | exit* | *[[:space:]]return | *[[:space:]]return[[:space:]]* | return*)
			printf '%s\tauto\t%s\n' "${line}" "${text}"
			;;
		*) printf '%s\tmanual\t%s (no exit after it: code below still runs today)\n' "${line}" "${text}" ;;
		esac
	done
}
