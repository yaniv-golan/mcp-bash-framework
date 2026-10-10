#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-fail-numeric
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SUMMARY="mcp_fail CODE MESSAGE (a protocol error the model can't see) is removed in 2.0"
MIG_FIX='mcp_fail --type TYPE "MESSAGE" [--hint TEXT] [--data JSON]'
mig_detect() {
	local line kind text
	mig_grep_word mcp_fail "$1" | while IFS=$'\t' read -r line kind text; do
		case "${text}" in
		*'mcp_fail --type'*) continue ;;
		*'mcp_fail -32602 '* | *'mcp_fail -32603 '*) printf '%s\tauto\t%s\n' "${line}" "${text}" ;;
		*) printf '%s\tmanual\t%s\n' "${line}" "${text}" ;;
		esac
	done
}
