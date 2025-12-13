#!/usr/bin/env bash
# Host policy helpers (allow/deny lists, normalization, private IP checks).

set -euo pipefail

mcp_policy_ipv4_is_private() {
	local ip="$1"
	case "${ip}" in
	"" | localhost | 127.* | 0.0.0.0 | 10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].* | 169.254.*)
		return 0
		;;
	esac
	return 1
}

mcp_policy_ipv4_from_v4mapped_hex() {
	# Convert IPv4-mapped IPv6 in hex form to dotted IPv4.
	# Examples:
	#   ::ffff:7f00:1            -> 127.0.0.1
	#   0:0:0:0:0:ffff:0a00:0001 -> 10.0.0.1
	local ip="$1"
	ip="$(printf '%s' "${ip}" | tr '[:upper:]' '[:lower:]')"
	# Strip brackets and zone IDs.
	if [ "${ip#\[}" != "${ip}" ]; then
		ip="${ip#[}"
		ip="${ip%]}"
	fi
	ip="${ip%%%*}"

	case "${ip}" in
	*":ffff:"*) ;;
	*)
		return 1
		;;
	esac

	# Use the last ":ffff:" segment (handles full forms with multiple hextets).
	local tail="${ip##*:ffff:}"
	# Must be two hextets separated by ":" (some stacks may omit leading zeros).
	case "${tail}" in
	*:*) ;;
	*) return 1 ;;
	esac
	local hi="${tail%%:*}"
	local lo="${tail#*:}"
	[ -n "${hi}" ] && [ -n "${lo}" ] || return 1
	# Ensure hex-only hextets up to 4 digits.
	if ! printf '%s' "${hi}" | grep -Eq '^[0-9a-f]{1,4}$'; then
		return 1
	fi
	if ! printf '%s' "${lo}" | grep -Eq '^[0-9a-f]{1,4}$'; then
		return 1
	fi

	local hi_val lo_val
	hi_val=$((16#${hi}))
	lo_val=$((16#${lo}))
	local a b c d
	a=$(((hi_val >> 8) & 255))
	b=$((hi_val & 255))
	c=$(((lo_val >> 8) & 255))
	d=$((lo_val & 255))
	printf '%s.%s.%s.%s' "${a}" "${b}" "${c}" "${d}"
}

mcp_policy_ip_is_private() {
	local ip="$1"
	# Normalize for matching: strip brackets and zone IDs, and lowercase.
	if [ "${ip#\[}" != "${ip}" ]; then
		ip="${ip#[}"
		ip="${ip%]}"
	fi
	ip="${ip%%%*}"
	ip="$(printf '%s' "${ip}" | tr '[:upper:]' '[:lower:]')"

	case "${ip}" in
	"" | localhost)
		return 0
		;;
	esac
	if mcp_policy_ipv4_is_private "${ip}"; then
		return 0
	fi
	case "${ip}" in
	::1 | "[::1]" | fe80:* | fc??:* | fd??:*)
		return 0
		;;
	::ffff:127.* | ::ffff:10.* | ::ffff:192.168.* | ::ffff:172.1[6-9].* | ::ffff:172.2[0-9].* | ::ffff:172.3[0-1].* | ::ffff:169.254.*)
		return 0
		;;
	::ffff:0:0:127.* | ::ffff:0:0:10.* | ::ffff:0:0:192.168.* | ::ffff:0:0:172.1[6-9].* | ::ffff:0:0:172.2[0-9].* | ::ffff:0:0:172.3[0-1].* | ::ffff:0:0:169.254.*)
		return 0
		;;
	esac
	# Catch IPv4-mapped IPv6 in hex hextet form (e.g., ::ffff:7f00:1).
	local mapped_v4=""
	mapped_v4="$(mcp_policy_ipv4_from_v4mapped_hex "${ip}" 2>/dev/null || true)"
	if [ -n "${mapped_v4}" ] && mcp_policy_ipv4_is_private "${mapped_v4}"; then
		return 0
	fi
	return 1
}

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
	# Parse the authority portion of a URL safely enough for SSRF defense:
	# - Strip path/query/fragment
	# - Strip userinfo (user:pass@) which is otherwise a bypass vector
	# - Support bracketed IPv6 literals with optional port
	local authority="${url#*://}"
	authority="${authority%%/*}"
	authority="${authority%%\?*}"
	authority="${authority%%\#*}"
	# If userinfo is present, keep only the host[:port] portion.
	authority="${authority##*@}"

	local host=""
	case "${authority}" in
	\[*\]*)
		# [ipv6]:port or [ipv6]
		host="${authority#\[}"
		host="${host%%\]*}"
		;;
	*)
		host="${authority%%:*}"
		;;
	esac

	mcp_policy_normalize_host "${host}"
}

mcp_policy_resolve_ips() {
	local host="$1"
	local resolved=""
	if command -v getent >/dev/null 2>&1; then
		resolved="$(getent ahosts "${host}" 2>/dev/null | awk '{print $1}')"
	fi
	if [ -z "${resolved}" ] && command -v dig >/dev/null 2>&1; then
		resolved="$(dig +short "${host}" A AAAA 2>/dev/null | sed '/^$/d')"
	fi
	if [ -z "${resolved}" ] && command -v host >/dev/null 2>&1; then
		resolved="$(host "${host}" 2>/dev/null | awk '/has address/{print $4}/IPv6 address/{print $5}')"
	fi
	if [ -z "${resolved}" ] && command -v nslookup >/dev/null 2>&1; then
		resolved="$(nslookup "${host}" 2>/dev/null | awk '/^Address: /{print $2}' | tail -n +2)"
	fi
	resolved="$(printf '%s\n' "${resolved}" | sed '/^$/d' | sort -u)"
	if [ -z "${resolved}" ]; then
		return 1
	fi
	printf '%s\n' "${resolved}"
}

mcp_policy_host_is_private() {
	local host="$1"
	local resolved_ips

	if mcp_policy_ip_is_private "${host}"; then
		return 0
	fi

	if resolved_ips="$(mcp_policy_resolve_ips "${host}")"; then
		while IFS= read -r ip; do
			[ -z "${ip}" ] && continue
			ip="$(printf '%s' "${ip}" | tr '[:upper:]' '[:lower:]')"
			if mcp_policy_ip_is_private "${ip}"; then
				return 0
			fi
		done <<EOF
${resolved_ips}
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
