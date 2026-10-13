#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-text-with-resource
MIG_API=2
MIG_KIND=auto
MIG_SCOPE="project-sh"
MIG_SET=envelope
MIG_SUMMARY="mcp_result_text_with_resource (sends the {success, result} envelope) is removed in 2.0"
MIG_FIX='mcp_result_json JSON --resource PATH [--mime TYPE] [--uri URI]'
# Part of the "envelope" set: like mcp_result_success it sent the envelope,
# so the tool's outputSchema and UI reads change together with it. The call
# and its "\" continuation lines are rewritten: the name, and --path to
# --resource. Manual instead when the result is captured with $(...) (its
# shape changes), when the call forwards "$@" (the callers pass --path,
# which mcp_result_json doesn't take), or when "--path" appears inside a
# quoted string on the call's lines.
mig_detect() {
	local file="$1" line kind text
	mig_grep_word mcp_result_text_with_resource "${file}" | while IFS=$'\t' read -r line kind text; do
		if mig_call_is_opaque mcp_result_text_with_resource "${text}"; then
			printf '%s\tmanual\t%s (captured or forwarding "$@": the result shape or the --path callers pass changes)\n' "${line}" "${text}"
		elif _mig_twr_quoted_path "${file}" "${line}"; then
			printf '%s\tmanual\t%s (--path inside a quoted string)\n' "${line}" "${text}"
		else
			printf '%s\tauto\t%s\n' "${line}" "${text}"
		fi
	done
}
# True when a quoted string on the call starting at line N of FILE (or its
# continuation lines) contains --path.
_mig_twr_quoted_path() {
	awk -v n="$2" -v q="'" '
		NR < n { next }
		{
			t = $0
			gsub(q "[^" q "]*" q, "", t)
			gsub(/"([^"\\]|\\.)*"/, "", t)
			raw = gsub(/--path/, "&", $0)
			bare = gsub(/--path/, "&", t)
			if (raw > bare) { found = 1; exit }
			if ($0 !~ /\\$/) exit
		}
		END { exit found ? 0 : 1 }' "$1"
}
mig_apply() {
	local file="$1" n="$2" text cont=1
	while [ "${cont}" = 1 ]; do
		text="$(mig_line "${file}" "${n}")"
		case "${text}" in
		*\\) cont=1 ;;
		*) cont=0 ;;
		esac
		text="$(printf '%s' "${text}" | sed -E \
			-e 's/(^|[^A-Za-z0-9_])mcp_result_text_with_resource([^A-Za-z0-9_]|$)/\1mcp_result_json\2/' \
			-e 's/(^|[[:space:]])--path([[:space:]])/\1--resource\2/g')"
		mig_replace_line "${file}" "${n}" "${text}"
		n=$((n + 1))
	done
}
