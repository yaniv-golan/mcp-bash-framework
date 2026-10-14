#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-policy-replace
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="server-sh"
MIG_SUMMARY="policy.sh defines mcp_tools_policy_check; 2.0 calls only mcp_tools_policy_project (after the built-in checks)"
MIG_FIX='rename to mcp_tools_policy_project; $2 is the call arguments (JSON); print the denial message to stdout and return 1'
# Auto only when the hook's first statement is the default check (no
# "declare -F" guard) and the rest uses neither $2 or $3 (1.x: tool metadata
# and call arguments; the new hook gets the arguments as $2, so a renamed body
# reading $3 would see nothing and could allow what it used to deny), nor
# "$@"/$*, nor the 1.x message globals (the new hook reports through stdout).
# Any other definition, a one-line one included, is reported for a manual
# change.
mig_detect() {
	local file="$1"
	case "${file##*/}" in policy.sh) ;; *) return 0 ;; esac
	local line
	line="$(grep -nE '^[[:space:]]*(function[[:space:]]+)?mcp_tools_policy_check[[:space:]]*(\(\))?[[:space:]]*\{?[[:space:]]*$' "${file}" | head -n 1 | cut -d: -f1)"
	if [ -z "${line}" ]; then
		# Defined some other way (on one line, say): never rewritten.
		line="$(grep -nE '^[[:space:]]*(function[[:space:]]+)?mcp_tools_policy_check[[:space:]]*([(]|[{]|$)' "${file}" | head -n 1 | cut -d: -f1)"
		[ -n "${line}" ] || return 0
		printf '%s\t%s\t%s\n' "${line}" manual "mcp_tools_policy_check (not a plain multi-line definition)"
		return 0
	fi
	local body first rest kind=manual
	body="$(awk -v n="${line}" 'NR > n { print } NR > n && /^}/ { exit }' "${file}")"
	first="$(printf '%s\n' "${body}" | grep -vE '^[[:space:]]*(#.*)?$' | head -n 1)"
	# The default call must be the whole first line (a trailing comment
	# aside): mig_apply deletes that line, so nothing else may be on it.
	local whole='^[[:space:]]*mcp_tools_policy_check_default "[$]@" [|][|] return 1[[:space:]]*(#.*)?$'
	if printf '%s\n' "${first}" | grep -qE "${whole}"; then
		# The body after that first statement. Manual when it reads the 1.x
		# arguments in any way: $2, $3, "$@", $*, $#, ${!...}, shift or set --.
		rest="$(printf '%s\n' "${body}" | awk -v f="${first}" 'done { print; next } $0 == f { done = 1 }')"
		if ! printf '%s\n' "${rest}" | grep -qE '[$][{]?[23*@#]|[$][{]!|(^|[^A-Za-z0-9_])shift([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])set[[:space:]]+--|_MCP_TOOLS_ERROR_|mcp_tools_error'; then
			kind=auto
		fi
	fi
	printf '%s\t%s\t%s\n' "${line}" "${kind}" "mcp_tools_policy_check() {"
}
# Rename the hook and drop the default call (2.0 runs the built-in checks first).
mig_apply() {
	local file="$1" n="$2" call tmp
	call="$(awk -v n="${n}" 'NR > n && $0 !~ /^[[:space:]]*(#.*)?$/ { print NR; exit }' "${file}")"
	mig_replace_line "${file}" "${n}" "$(mig_line "${file}" "${n}" | sed 's/mcp_tools_policy_check/mcp_tools_policy_project/')" || return 1
	[ -n "${call}" ] || return 0
	tmp="$(mktemp "${file}.mig.XXXXXX")" || return 1
	awk -v n="${call}" 'NR != n' "${file}" >"${tmp}" && cat "${tmp}" >"${file}"
	rm -f "${tmp}"
}
