#!/usr/bin/env bash
# Pagination cursor helpers.

set -euo pipefail

mcp_paginate_base64_urldecode() {
	local input="$1"
	local converted="${input//-/+}"
	converted="${converted//_/\/}"
	local pad=$(((4 - (${#converted} % 4)) % 4))
	case "${pad}" in
	1) converted="${converted}=" ;;
	2) converted="${converted}==" ;;
	3) converted="${converted}===" ;;
	esac
	local decoded
	if decoded="$(printf '%s' "${converted}" | base64 --decode 2>/dev/null)"; then
		printf '%s' "${decoded}"
		return 0
	fi
	if decoded="$(printf '%s' "${converted}" | base64 -d 2>/dev/null)"; then
		printf '%s' "${decoded}"
		return 0
	fi
	if decoded="$(printf '%s' "${converted}" | base64 -D 2>/dev/null)"; then
		printf '%s' "${decoded}"
		return 0
	fi
	if command -v openssl >/dev/null 2>&1; then
		if decoded="$(printf '%s' "${converted}" | openssl base64 -d -A 2>/dev/null)"; then
			printf '%s' "${decoded}"
			return 0
		fi
	fi
	return 1
}

mcp_paginate_encode() {
	local collection="$1"
	local offset="$2"
	local hash="$3"
	local timestamp="${4:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
	local payload encoded

	payload="$("${MCPBASH_JSON_TOOL_BIN}" -n \
		--arg collection "${collection}" \
		--argjson offset "${offset:-0}" \
		--arg hash "${hash}" \
		--arg timestamp "${timestamp}" \
		'{ver: 1, collection: $collection, offset: $offset, hash: $hash, timestamp: $timestamp}')" || return 1
	encoded="$(printf '%s' "${payload}" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')"
	printf '%s' "${encoded}"
}

mcp_paginate_decode() {
	local cursor="$1"
	local expected_collection="$2"
	local expected_hash="$3"
	local decoded

	if [ -z "${cursor}" ]; then
		return 1
	fi

	decoded="$(mcp_paginate_base64_urldecode "${cursor}")" || return 1

	local offset collection hash
	collection="$(printf '%s' "${decoded}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.collection // empty')" || return 1
	if [ "${collection}" != "${expected_collection}" ] || [ -z "${collection}" ]; then
		return 1
	fi
	hash="$(printf '%s' "${decoded}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty')" || return 1
	if [ -n "${expected_hash}" ] && [ "${hash}" != "${expected_hash}" ]; then
		return 2
	fi
	offset="$(printf '%s' "${decoded}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.offset // 0')" || return 1
	if ! [[ "${offset}" =~ ^[0-9]+$ ]]; then
		return 1
	fi
	printf '%s' "${offset}"
}

mcp_paginate_attach_next_cursor() {
	local json_payload="$1"
	local collection="$2"
	local offset="$3"
	local limit="$4"
	local total="$5"
	local hash="$6"

	if [ $((offset + limit)) -lt "${total}" ]; then
		local next_offset cursor_payload encoded
		next_offset=$((offset + limit))
		cursor_payload="$("${MCPBASH_JSON_TOOL_BIN}" -n --arg ver "1" --arg col "${collection}" --argjson off "${next_offset}" --arg hash "${hash}" '{ver: $ver|tonumber, collection: $col, offset: $off, hash: $hash}')" || return 1
		encoded="$(printf '%s' "${cursor_payload}" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')"
		printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c --arg next "${encoded}" '.nextCursor = $next'
		return 0
	fi

	printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.nextCursor = null'
}
