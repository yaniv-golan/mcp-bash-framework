#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-mcp-error
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SUMMARY="mcp_error is removed in 2.0 (mcp_fail --type ends the tool; mcp_error did not)"
MIG_FIX='mcp_fail --type TYPE "MESSAGE" [--hint TEXT] [--data JSON]'
# Auto only when an unconditional exit follows: mcp_fail ends the tool, so
# code after an mcp_error, or a caller continuing after a "return", would
# silently stop running. The exit is either the next statement on its own
# (`exit`, `exit N`, optionally followed by `;`, `;;`, `; fi`/`done`/`esac`/`}`
# or a comment) or the last statement on the same line (`mcp_error ...; exit 0`,
# also inside `{ ...; exit; }` or a case arm). A conditional exit, an exit
# combined with && or ||, or the word in a string stays manual.
mig_detect() {
	local file="$1" line kind text next
	# An exit status word; no quotes, so a string ending in "; exit 0" isn't one.
	local word='[^[:space:];&|<>()"'\'']+'
	local alone="^[[:space:]]*exit([[:space:]]+${word})?[[:space:]]*(;;?[[:space:]]*|;[[:space:]]*(fi|done|esac|\\})[[:space:]]*)?(#.*)?\$"
	local same=";[[:space:]]*exit([[:space:]]+${word})?[[:space:]]*(;[[:space:]]*\\}?|;;)?[[:space:]]*(#.*)?\$"
	mig_grep_word mcp_error "${file}" | while IFS=$'\t' read -r line kind text; do
		if [[ ${text} =~ ${same} ]]; then
			printf '%s\tauto\t%s\n' "${line}" "${text}"
			continue
		fi
		next="$(mig_next_statement "${file}" "${line}")"
		if [[ ${next} =~ ${alone} ]]; then
			printf '%s\tauto\t%s\n' "${line}" "${text}"
		else
			printf '%s\tmanual\t%s (no unconditional exit after it: code below still runs today)\n' "${line}" "${text}"
		fi
	done
}
mig_apply() {
	local text
	text="$(mig_line "$1" "$2" | sed -E 's/(^|[^A-Za-z0-9_])mcp_error([^A-Za-z0-9_]|$)/\1mcp_fail --type\2/')"
	mig_replace_line "$1" "$2" "${text}"
}
