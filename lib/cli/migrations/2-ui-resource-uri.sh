#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-ui-resource-uri
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="project-sh"
MIG_SUMMARY="mcp_result_with_ui[_data] are removed in 2.0 (their resource_uri argument was ignored)"
MIG_FIX='mcp_result_ui "TEXT" [DATA]'
# Auto when the first argument is an empty literal ("" or ''), which drops
# without changing anything; a non-empty URI is manual (check it is unused).
mig_detect() {
	local line kind text
	mig_grep_regex '(^|[^A-Za-z0-9_])mcp_result_with_ui(_data)?([^A-Za-z0-9_]|$)' "$1" | while IFS=$'\t' read -r line kind text; do
		case "${text}" in
		*'mcp_result_with_ui "" '* | *"mcp_result_with_ui '' "* | *'mcp_result_with_ui_data "" '* | *"mcp_result_with_ui_data '' "*)
			printf '%s\tauto\t%s\n' "${line}" "${text}"
			;;
		*) printf '%s\tmanual\t%s\n' "${line}" "${text}" ;;
		esac
	done
}
mig_apply() {
	local text
	text="$(mig_line "$1" "$2" | sed -E \
		-e "s/(^|[^A-Za-z0-9_])mcp_result_with_ui(_data)? (\"\"|'') /\\1mcp_result_ui /")"
	mig_replace_line "$1" "$2" "${text}"
}
