#!/usr/bin/env bash
# Resource provider: fetch content from HTTPS endpoints.

set -euo pipefail

mcp_https_main() {
	local uri="${1:-}"
	if [ -z "${uri}" ] || [[ "${uri}" != https://* ]]; then
		printf '%s\n' "HTTPS provider requires https:// URI" >&2
		return 4
	fi
	local timeout_secs="${MCPBASH_HTTPS_TIMEOUT:-15}"
	case "${timeout_secs}" in
	'' | *[!0-9]*) timeout_secs=15 ;;
	esac
	local max_bytes="${MCPBASH_HTTPS_MAX_BYTES:-10485760}"
	case "${max_bytes}" in
	'' | *[!0-9]*) max_bytes=10485760 ;;
	esac
	local tmp_file
	tmp_file="$(mktemp "${TMPDIR:-/tmp}/mcp-https.XXXXXX")"
	cleanup_tmp() {
		rm -f "${tmp_file}"
	}
	trap cleanup_tmp EXIT

	if command -v curl >/dev/null 2>&1; then
		if ! curl -fsSL --max-time "${timeout_secs}" --connect-timeout "${timeout_secs}" --max-filesize "${max_bytes}" -o "${tmp_file}" "${uri}"; then
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
		if ! wget -q --timeout="${timeout_secs}" -O "${tmp_file}" "${uri}"; then
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
