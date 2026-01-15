#!/usr/bin/env bash
# Resource provider: fetch content from HTTPS endpoints.

set -euo pipefail

mcp_https_load_policy() {
	# Prefer shared policy helpers. If they cannot be loaded, fall back to local
	# implementations that STILL enforce allow/deny lists (never fail-open).
	local sourced="false"
	if [ -n "${MCPBASH_HOME:-}" ] && [ -f "${MCPBASH_HOME}/lib/policy.sh" ]; then
		# shellcheck disable=SC1090
		if . "${MCPBASH_HOME}/lib/policy.sh"; then sourced="true"; fi
	fi
	if [ "${sourced}" != "true" ]; then
		local self_dir=""
		self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P 2>/dev/null)" || true
		if [ -n "${self_dir}" ] && [ -f "${self_dir%/}/../lib/policy.sh" ]; then
			# shellcheck disable=SC1090,SC1091
			if . "${self_dir%/}/../lib/policy.sh"; then sourced="true"; fi
		fi
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
	fi

	if ! command -v mcp_policy_normalize_host >/dev/null 2>&1; then
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
	fi

	if ! command -v mcp_policy_host_allowed >/dev/null 2>&1; then
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

mcp_https_extract_port_from_url() {
	# Extract port from an https:// URL. Defaults to 443 when absent/invalid.
	# Must strip userinfo (user:pass@) to avoid SSRF bypasses.
	local url="$1"
	local authority="${url#*://}"
	authority="${authority%%/*}"
	authority="${authority%%\?*}"
	authority="${authority%%\#*}"
	authority="${authority##*@}"
	local port="443"

	case "${authority}" in
	\[*\]*)
		# [ipv6]:port or [ipv6]
		case "${authority}" in
		*"]:"*)
			port="${authority##*]:}"
			;;
		esac
		;;
	*)
		# host:port or host
		if [[ "${authority}" == *:* ]]; then
			port="${authority##*:}"
		fi
		;;
	esac

	case "${port}" in
	'' | *[!0-9]*) port="443" ;;
	esac
	if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
		port="443"
	fi
	printf '%s' "${port}"
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
	local port
	port="$(mcp_https_extract_port_from_url "${uri}")"
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
	local -a resolved_ip_list=()
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
				resolved_ip_list+=("${ip}")
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
	local user_agent="${MCPBASH_HTTPS_USER_AGENT:-}"

	local tmp_file header_file
	tmp_file="$(mktemp "${TMPDIR:-/tmp}/mcp-https.XXXXXX")"
	header_file="$(mktemp "${TMPDIR:-/tmp}/mcp-https-hdr.XXXXXX")"
	# NOTE: EXIT traps run after function locals go out of scope. Capture the
	# temp paths via globals so set -u doesn't trip on unbound locals.
	MCPBASH_HTTPS_TMP_FILE="${tmp_file}"
	MCPBASH_HTTPS_HDR_FILE="${header_file}"
	trap 'rm -f -- "${MCPBASH_HTTPS_TMP_FILE:-}" "${MCPBASH_HTTPS_HDR_FILE:-}"' EXIT

	if command -v curl >/dev/null 2>&1; then
		# Build optional curl arguments (e.g., User-Agent)
		local -a curl_opts=()
		if [ -n "${user_agent}" ]; then
			curl_opts+=(-A "${user_agent}")
		fi

		# DNS rebinding defense: if we resolved IPs, pin the connection to the
		# vetted IP(s) via --resolve so curl does not re-resolve during fetch.
		# If multiple IPs exist, try them in order (all were checked as public).
		local curl_rc=0
		local tried_any="false"
		if [ "${#resolved_ip_list[@]}" -gt 0 ]; then
			local ip http_code location
			for ip in "${resolved_ip_list[@]}"; do
				tried_any="true"
				# Capture HTTP code and headers in single request (with all security flags)
				# NOTE: Remove -f flag to get HTTP status codes instead of curl failing on 4xx/5xx
				# NOTE: ${curl_opts[@]+"${curl_opts[@]}"} safely handles empty arrays with set -u
				# CRITICAL: Do NOT use 2>&1 - stderr must stay separate to avoid corrupting http_code
				http_code=$(curl -w '%{http_code}' -D "${header_file}" -o "${tmp_file}" \
					-sS ${curl_opts[@]+"${curl_opts[@]}"} \
					--max-time "${timeout_secs}" --connect-timeout "${timeout_secs}" \
					--max-filesize "${max_bytes}" \
					--proto '=https' --proto-redir '=https' --max-redirs 0 \
					--resolve "${host}:${port}:${ip}" \
					"${uri}") && curl_rc=0 || curl_rc=$?

				# Check curl exit code FIRST (before examining http_code)
				if [[ $curl_rc -ne 0 ]]; then
					[[ $curl_rc -eq 63 ]] && return 6 # Size exceeded
					continue # Try next IP
				fi

				# Handle http_code "000" - curl succeeded but no HTTP response (rare edge case)
				if [[ "${http_code}" == "000" ]]; then
					curl_rc=1 # Force non-zero so we don't accidentally succeed
					continue # Try next IP
				fi

				# Check for redirect status (3xx) - exit code 7
				# NOTE: Multi-IP redirect behavior is "first redirect wins"
				if [[ "${http_code}" =~ ^3[0-9][0-9]$ ]]; then
					location=$(grep -i '^location:' "${header_file}" | sed 's/^[^:]*: *//' | tr -d '\r\n')
					printf 'redirect:%s\n' "${location}" >&2
					return 7
				fi

				# Check for HTTP errors (4xx/5xx)
				# NOTE: All HTTP errors return exit 5 (network_error). 404 is permanent but
				# will still be retried - this is a known v1 limitation.
				if [[ "${http_code}" =~ ^[45][0-9][0-9]$ ]]; then
					printf 'HTTP error: %s\n' "${http_code}" >&2
					return 5
				fi

				# Success (2xx) - break out of IP loop
				break
			done
			if [ "${curl_rc}" -ne 0 ]; then
				return 5
			fi
		fi
		if [ "${tried_any}" != "true" ]; then
			local http_code location
			http_code=$(curl -w '%{http_code}' -D "${header_file}" -o "${tmp_file}" \
				-sS ${curl_opts[@]+"${curl_opts[@]}"} \
				--max-time "${timeout_secs}" --connect-timeout "${timeout_secs}" \
				--max-filesize "${max_bytes}" \
				--proto '=https' --proto-redir '=https' --max-redirs 0 \
				"${uri}") && curl_rc=0 || curl_rc=$?

			if [[ $curl_rc -ne 0 ]]; then
				[[ $curl_rc -eq 63 ]] && return 6 # Size exceeded
				return 5
			fi
			if [[ "${http_code}" == "000" ]]; then
				return 5
			fi
			if [[ "${http_code}" =~ ^3[0-9][0-9]$ ]]; then
				location=$(grep -i '^location:' "${header_file}" | sed 's/^[^:]*: *//' | tr -d '\r\n')
				printf 'redirect:%s\n' "${location}" >&2
				return 7
			fi
			if [[ "${http_code}" =~ ^[45][0-9][0-9]$ ]]; then
				printf 'HTTP error: %s\n' "${http_code}" >&2
				return 5
			fi
		fi
	else
		# Security note: we intentionally require curl because it supports DNS
		# pinning via --resolve to mitigate DNS rebinding between pre-check and
		# the actual fetch. wget cannot be pinned equivalently.
		printf '%s\n' "curl is required for HTTPS provider" >&2
		return 4
	fi

	cat "${tmp_file}"
}

mcp_https_main "$@"
