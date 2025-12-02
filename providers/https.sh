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
			local host="${url#*://}"
			host="${host%%/*}"
			host="${host%%:*}"
			host="${host#\[}"
			host="${host%\]}"
			printf '%s' "${host}" | tr '[:upper:]' '[:lower:]'
		}
		mcp_policy_host_is_private() {
			local host="$1"
			case "${host}" in
			"" | localhost | 127.* | 0.0.0.0 | ::1 | "[::1]" | 10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].* | 169.254.*)
				return 0
				;;
			esac
			return 1
		}
		mcp_policy_host_allowed() {
			return 0
		}
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
		printf '%s\n' "HTTPS provider blocked internal/unsupported host" >&2
		return 4
	fi
	if mcp_policy_host_is_private "${host}"; then
		printf '%s\n' "HTTPS provider blocked internal/unsupported host" >&2
		return 4
	fi
	if ! mcp_policy_host_allowed "${host}" "${MCPBASH_HTTPS_ALLOW_HOSTS:-}" "${MCPBASH_HTTPS_DENY_HOSTS:-}"; then
		printf '%s\n' "HTTPS provider blocked internal/unsupported host" >&2
		return 4
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
		if ! wget -q --timeout="${timeout_secs}" --max-redirect=0 --https-only -O "${tmp_file}" "${uri}"; then
			return 5
		fi
		local local_size
		local_size="$(wc -c <"${tmp_file}" | tr -d ' ')"
		if [ "${local_size}" -gt "${max_bytes}" ]; then
			printf 'Payload exceeds %s bytes\n' "${max_bytes}" >&2
			return 6
		fi
	else
		printf '%s\n' "Neither curl nor wget available for HTTPS provider" >&2
		return 4
	fi

	cat "${tmp_file}"
}

mcp_https_main "$@"
