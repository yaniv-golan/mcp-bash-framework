#!/usr/bin/env bash
# Host policy helpers (allow/deny lists, normalization, private IP checks).

set -euo pipefail

mcp_policy_normalize_host() {
	local host="$1"
	if [ -z "${host}" ]; then
		return 1
	fi
	if [ "${host#\[}" != "${host}" ]; then
		host="${host#[}"
		host="${host%]}"
	fi
	printf '%s' "${host}" | tr '[:upper:]' '[:lower:]'
}

mcp_policy_extract_host_from_url() {
	local url="$1"
	local host="${url#*://}"
	host="${host%%/*}"
	host="${host%%:*}"
	mcp_policy_normalize_host "${host}"
}

mcp_policy_host_is_private() {
	local host="$1"
	case "${host}" in
	"" | localhost | 127.* | 0.0.0.0 | ::1 | "[::1]" | 10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].* | 169.254.*)
		return 0
		;;
	esac
	if command -v getent >/dev/null 2>&1 && getent ahosts "${host}" >/dev/null 2>&1; then
		while read -r ip _; do
			case "${ip}" in
			10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].* | 127.* | 169.254.* | ::1 | fe80:* | fc??:* | fd??:*)
				return 0
				;;
			esac
		done <<EOF
$(getent ahosts "${host}" | awk '{print $1}')
EOF
	fi
	return 1
}

mcp_policy_host_match_list() {
	local host="$1"
	local list="$2"
	local token
	list="${list//,/ }"
	for token in ${list}; do
		[ -z "${token}" ] && continue
		if [ "${host}" = "$(mcp_policy_normalize_host "${token}")" ]; then
			return 0
		fi
	done
	return 1
}

mcp_policy_host_allowed() {
	local host="$1"
	local allow_list="$2"
	local deny_list="$3"
	if [ -n "${deny_list}" ] && mcp_policy_host_match_list "${host}" "${deny_list}"; then
		return 1
	fi
	if [ -n "${allow_list}" ]; then
		if mcp_policy_host_match_list "${host}" "${allow_list}"; then
			return 0
		fi
		return 1
	fi
	return 0
}
