#!/usr/bin/env bash
# Resource provider: fetch content from HTTPS endpoints.

set -euo pipefail

uri="${1:-}"
if [ -z "${uri}" ] || [[ "${uri}" != https://* ]]; then
	printf '%s\n' "HTTPS provider requires https:// URI" >&2
	exit 4
fi
timeout_secs="${MCPBASH_HTTPS_TIMEOUT:-15}"
case "${timeout_secs}" in
'' | *[!0-9]*) timeout_secs=15 ;;
esac
max_bytes="${MCPBASH_HTTPS_MAX_BYTES:-10485760}"
case "${max_bytes}" in
'' | *[!0-9]*) max_bytes=10485760 ;;
esac
tmp_file="$(mktemp "${TMPDIR:-/tmp}/mcp-https.XXXXXX")"
cleanup_tmp() {
	rm -f "${tmp_file}"
}
trap cleanup_tmp EXIT

if command -v curl >/dev/null 2>&1; then
	if ! curl -fsSL --max-time "${timeout_secs}" --connect-timeout "${timeout_secs}" --max-filesize "${max_bytes}" -o "${tmp_file}" "${uri}"; then
		exit 5
	fi
elif command -v wget >/dev/null 2>&1; then
	if ! wget -q --timeout="${timeout_secs}" -O "${tmp_file}" "${uri}"; then
		exit 5
	fi
	local_size="$(wc -c <"${tmp_file}" | tr -d ' ')"
	if [ "${local_size}" -gt "${max_bytes}" ]; then
		exit 5
	fi
else
	printf '%s\n' "Neither curl nor wget available for HTTPS provider" >&2
	exit 4
fi

cat "${tmp_file}"
