#!/usr/bin/env bash
# Shared hashing helpers.

set -euo pipefail

mcp_hash_string() {
	local value="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "${value}" | sha256sum | awk '{print $1}'
		return 0
	fi
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "${value}" | shasum -a 256 | awk '{print $1}'
		return 0
	fi
	printf '%s' "${value}" | cksum | awk '{print $1}'
}

mcp_hash_json_payload() {
	local payload="$1"
	local compact="${payload}"

	if [ -n "${MCPBASH_JSON_TOOL_BIN:-}" ] && command -v "${MCPBASH_JSON_TOOL_BIN}" >/dev/null 2>&1; then
		if compact="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.' 2>/dev/null)"; then
			:
		else
			compact="${payload}"
		fi
	fi

	mcp_hash_string "${compact}"
}
