#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-fail-numeric
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SUMMARY="mcp_fail CODE MESSAGE (a protocol error the model can't see) is removed in 2.0"
MIG_FIX='mcp_fail --type TYPE "MESSAGE" [--hint TEXT] [--data JSON]'
# Auto for -32602/-32603 with a single message argument; other codes, a
# variable code or a data argument are manual. The 2.0 message forms
# (mcp_fail MESSAGE [--hint T] [--data J], mcp_fail -- MESSAGE) are not
# findings: --type is optional in 2.0.
mig_detect() {
	local line kind text
	mig_grep_word mcp_fail "$1" | while IFS=$'\t' read -r line kind text; do
		case "${text}" in
		*'mcp_fail --type'*) continue ;;
		*'mcp_fail -32602 '* | *'mcp_fail -32603 '*)
			if [ "$(mig_call_argc mcp_fail "${text}")" = "2" ] && ! mig_call_is_opaque mcp_fail "${text}"; then
				printf '%s\tauto\t%s\n' "${line}" "${text}"
			else
				printf '%s\tmanual\t%s\n' "${line}" "${text}"
			fi
			;;
		*)
			local rest first argc
			rest="${text#*mcp_fail}"
			rest="${rest#"${rest%%[![:space:]]*}"}"
			first="${rest%%[[:space:]]*}"
			argc="$(mig_call_argc mcp_fail "${text}")"
			case "${first}" in
			--*) continue ;;
			[-+0-9]*) printf '%s\tmanual\t%s\n' "${line}" "${text}" ;;
			*)
				# A message alone, or a message with --hint/--data, is the
				# 2.0 form; two positional arguments may be CODE MESSAGE.
				case "${argc}" in
				'' | 0 | 1) continue ;;
				esac
				case "${text}" in
				*' --hint'* | *' --data'*) continue ;;
				esac
				printf '%s\tmanual\t%s\n' "${line}" "${text}"
				;;
			esac
			;;
		esac
	done
}
mig_apply() {
	local text
	text="$(mig_line "$1" "$2" | sed -E \
		-e 's/(^|[^A-Za-z0-9_])mcp_fail -32602 /\1mcp_fail --type invalid_args /' \
		-e 's/(^|[^A-Za-z0-9_])mcp_fail -32603 /\1mcp_fail --type internal /')"
	mig_replace_line "$1" "$2" "${text}"
}
