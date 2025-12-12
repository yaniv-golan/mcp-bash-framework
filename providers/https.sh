#!/usr/bin/env bash
# Resource provider: fetch content from HTTPS endpoints.

set -euo pipefail

mcp_https_load_policy() {
	if command -v mcp_policy_extract_host_from_url >/dev/null 2>&1; then
		return
	fi
	if [ -n "${MCPBASH_HOME:-}" ] && [ -f "${MCPBASH_HOME}/lib/policy.sh" ]; then
		# shellcheck disable=SC1090
		. "${MCPBASH_HOME}/lib/policy.sh"
	fi
	if ! command -v mcp_policy_extract_host_from_url >/dev/null 2>&1; then
		mcp_policy_extract_host_from_url() {
			local url="$1"
			# Best-effort URL host extraction for fallback mode. This must strip
			# userinfo (user:pass@) to avoid SSRF bypasses.
			local authority="${url#*://}"
			authority="${authority%%/*}"
			authority="${authority%%\?*}"
			authority="${authority%%\#*}"
			authority="${authority##*@}"
			local host=""
			case "${authority}" in
			\[*\]*)
				host="${authority#\[}"
				host="${host%%\]*}"
				;;
			*)
				host="${authority%%:*}"
				;;
			esac
			printf '%s' "${host}" | tr '[:upper:]' '[:lower:]'
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
			case "${host}" in
			"" | localhost | 127.* | 0.0.0.0 | ::1 | "[::1]" | 10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].* | 169.254.*)
				return 0
				;;
			esac
			if resolved_ips="$(mcp_policy_resolve_ips "${host}")"; then
				while IFS= read -r ip; do
					[ -z "${ip}" ] && continue
					case "${ip}" in
					10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].* | 127.* | 169.254.* | ::1 | fe80:* | fc??:* | fd??:* | ::ffff:127.* | ::ffff:10.* | ::ffff:192.168.* | ::ffff:172.1[6-9].* | ::ffff:172.2[0-9].* | ::ffff:172.3[0-1].* | ::ffff:169.254.* | ::ffff:0:0:127.* | ::ffff:0:0:10.* | ::ffff:0:0:192.168.* | ::ffff:0:0:172.1[6-9].* | ::ffff:0:0:172.2[0-9].* | ::ffff:0:0:172.3[0-1].* | ::ffff:0:0:169.254.*)
						return 0
						;;
					esac
				done <<EOF
${resolved_ips}
EOF
			fi
			return 1
		}
		mcp_policy_host_allowed() {
			return 0
		}
	fi
}

mcp_https_host_is_obfuscated_ip_literal() {
	# Reject non-canonical IP literals that some HTTP stacks accept:
	# - integer IPv4 (e.g., 2130706433)
	# - hex integer IPv4 (e.g., 0x7f000001)
	# - dotted quads with leading-zero octets (potential octal interpretation)
	local host="$1"
	case "${host}" in
	'') return 0 ;;
	esac
	# Explicitly allow bracket-free normal forms we expect here (brackets are stripped).
	if [[ "${host}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
		# Reject octets like 010.001.002.003 (ambiguous in some parsers).
		case "${host}" in
		*".0"[0-9]* | "0"[0-9]*.*)
			# Allow "0." and ".0" when the octet is exactly "0"
			case "${host}" in
			0.* | *.0) return 1 ;;
			esac
			# If any octet has a leading zero and more digits, reject.
			if printf '%s' "${host}" | grep -Eq '(^|\\.)0[0-9]+(\\.|$)'; then
				return 0
			fi
			;;
		esac
		return 1
	fi
	# Pure numeric hostnames are suspicious (may be interpreted as integer IPv4).
	if printf '%s' "${host}" | grep -Eq '^[0-9]+$'; then
		return 0
	fi
	# Hex integer IPv4
	if printf '%s' "${host}" | grep -Eq '^0x[0-9a-f]+$'; then
		return 0
	fi
	return 1
}

mcp_https_log_block() {
	local host="$1"
	if command -v mcp_logging_warning >/dev/null 2>&1; then
		mcp_logging_warning "mcp.https" "Blocked host ${host}"
	else
		printf '%s\n' "HTTPS provider blocked host ${host}" >&2
	fi
}

mcp_https_main() {
	mcp_https_load_policy
	local uri="${1:-}"
	if [ -z "${uri}" ] || [[ "${uri}" != https://* ]]; then
		printf '%s\n' "HTTPS provider requires https:// URI" >&2
		return 4
	fi

	local host
	host="$(mcp_policy_extract_host_from_url "${uri}")"
	if [ -z "${host}" ]; then
		mcp_https_log_block "<empty>"
		return 4
	fi
	if mcp_https_host_is_obfuscated_ip_literal "${host}"; then
		mcp_https_log_block "${host}"
		return 4
	fi
	if mcp_policy_host_is_private "${host}"; then
		mcp_https_log_block "${host}"
		return 4
	fi
	# Deny-by-default egress: require an explicit allowlist unless operators
	# intentionally opt into allow-all.
	local allow_all_raw="${MCPBASH_HTTPS_ALLOW_ALL:-false}"
	local allow_all="false"
	case "${allow_all_raw}" in
	true | 1 | yes | on) allow_all="true" ;;
	esac
	if [ "${allow_all}" != "true" ] && [ -z "${MCPBASH_HTTPS_ALLOW_HOSTS:-}" ]; then
		mcp_https_log_block "${host}"
		printf '%s\n' "HTTPS provider requires MCPBASH_HTTPS_ALLOW_HOSTS (or MCPBASH_HTTPS_ALLOW_ALL=true)" >&2
		return 4
	fi
	if ! mcp_policy_host_allowed "${host}" "${MCPBASH_HTTPS_ALLOW_HOSTS:-}" "${MCPBASH_HTTPS_DENY_HOSTS:-}"; then
		mcp_https_log_block "${host}"
		return 4
	fi
	if command -v mcp_policy_resolve_ips >/dev/null 2>&1; then
		local resolved_ips=""
		if resolved_ips="$(mcp_policy_resolve_ips "${host}")"; then
			while IFS= read -r ip; do
				[ -z "${ip}" ] && continue
				case "${ip}" in
				10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].* | 127.* | 169.254.* | ::1 | fe80:* | fc??:* | fd??:* | ::ffff:127.* | ::ffff:10.* | ::ffff:192.168.* | ::ffff:172.1[6-9].* | ::ffff:172.2[0-9].* | ::ffff:172.3[0-1].* | ::ffff:169.254.* | ::ffff:0:0:127.* | ::ffff:0:0:10.* | ::ffff:0:0:192.168.* | ::ffff:0:0:172.1[6-9].* | ::ffff:0:0:172.2[0-9].* | ::ffff:0:0:172.3[0-1].* | ::ffff:0:0:169.254.*)
					mcp_https_log_block "${host}"
					return 4
					;;
				esac
			done <<EOF
${resolved_ips}
EOF
		fi
	fi

	local timeout_secs="${MCPBASH_HTTPS_TIMEOUT:-15}"
	local timeout_ceil=60
	case "${timeout_secs}" in
	'' | *[!0-9]*) timeout_secs=15 ;;
	esac
	if [ "${timeout_secs}" -gt "${timeout_ceil}" ]; then
		timeout_secs="${timeout_ceil}"
	fi
	local max_bytes="${MCPBASH_HTTPS_MAX_BYTES:-10485760}"
	local max_bytes_ceil=20971520
	case "${max_bytes}" in
	'' | *[!0-9]*) max_bytes=10485760 ;;
	esac
	if [ "${max_bytes}" -gt "${max_bytes_ceil}" ]; then
		max_bytes="${max_bytes_ceil}"
	fi

	local tmp_file
	tmp_file="$(mktemp "${TMPDIR:-/tmp}/mcp-https.XXXXXX")"
	cleanup_tmp() {
		rm -f "${tmp_file}"
	}
	trap cleanup_tmp EXIT

	if command -v curl >/dev/null 2>&1; then
		if ! curl -fsS --max-time "${timeout_secs}" --connect-timeout "${timeout_secs}" --max-filesize "${max_bytes}" --proto '=https' --proto-redir '=https' --max-redirs 0 -o "${tmp_file}" "${uri}"; then
			case "$?" in
			63)
				printf 'Payload exceeds %s bytes\n' "${max_bytes}" >&2
				return 6
				;; # CURLE_FILESIZE_EXCEEDED
			*)
				return 5
				;;
			esac
		fi
	elif command -v wget >/dev/null 2>&1; then
		local limit_plus_one=$((max_bytes + 1))
		local wget_status=0
		local head_status=0
		if ! wget -q --timeout="${timeout_secs}" --max-redirect=0 --https-only -O - "${uri}" | head -c "${limit_plus_one}" >"${tmp_file}"; then
			wget_status=${PIPESTATUS[0]:-0}
			head_status=${PIPESTATUS[1]:-0}
			if [ "${head_status}" -eq 141 ]; then
				head_status=0
			fi
		else
			wget_status=${PIPESTATUS[0]:-0}
			head_status=${PIPESTATUS[1]:-0}
		fi
		local local_size
		local_size="$(wc -c <"${tmp_file}" | tr -d ' ')"
		if [ "${local_size}" -gt "${max_bytes}" ]; then
			printf 'Payload exceeds %s bytes\n' "${max_bytes}" >&2
			return 6
		fi
		if [ "${wget_status}" -ne 0 ] || [ "${head_status}" -ne 0 ]; then
			return 5
		fi
	else
		printf '%s\n' "Neither curl nor wget available for HTTPS provider" >&2
		return 4
	fi

	cat "${tmp_file}"
}

mcp_https_main "$@"
