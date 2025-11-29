#!/usr/bin/env bash
# Root resolution helpers for ffmpeg-studio using MCP roots.

set -euo pipefail

FFMPEG_STUDIO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ffmpeg_normalize_path() {
	local path="$1"
	if command -v realpath >/dev/null 2>&1; then
		if realpath -m "${path}" 2>/dev/null; then
			return 0
		fi
		if realpath "${path}" 2>/dev/null; then
			return 0
		fi
	fi
	# Fallback: manual absolute resolution
	if [[ "${path}" != /* ]]; then
		path="$(pwd)/${path}"
	fi
	# Clean up trailing slash (except root)
	if [[ "${path}" != "/" ]]; then
		path="${path%/}"
	fi
	printf '%s\n' "${path}"
}

ffmpeg_require_roots() {
	if [ -n "${MCP_ROOTS_PATHS:-}" ]; then
		return 0
	fi

	# Developer-friendly default: fall back to the example media folder so the
	# example works out of the box without configuring roots.
	local default_root
	default_root="$(ffmpeg_normalize_path "${FFMPEG_STUDIO_ROOT}/media")" || mcp_fail -32603 "Unable to resolve default media root"
	MCP_ROOTS_PATHS="${default_root}"
	MCP_ROOTS_COUNT=1
	MCP_ROOTS_JSON="[{\"uri\":\"file://${default_root}\",\"name\":\"Media\",\"path\":\"${default_root}\"}]"
}

ffmpeg_resolve_path() {
	local user_path="$1"
	local mode="${2:-read}" # read|write

	[ -n "${user_path}" ] || mcp_fail_invalid_args "Path cannot be empty"

	ffmpeg_require_roots

	if [[ "${user_path}" == "~"* ]]; then
		user_path="${user_path/#\~/${HOME}}"
	fi
	if [[ "${user_path}" == ./* ]]; then
		user_path="${user_path#./}"
	fi

	local canonical=""

	if [[ "${user_path}" == /* ]]; then
		canonical="$(ffmpeg_normalize_path "${user_path}")" || mcp_fail -32603 "Unable to resolve path: ${user_path}"
		if ! mcp_roots_contains "${canonical}"; then
			mcp_fail -32602 "Access denied: ${user_path} is outside allowed roots"
		fi
	else
		while IFS= read -r root; do
			[ -n "${root}" ] || continue
			local candidate="${root}/${user_path}"
			local attempt
			if ! attempt="$(ffmpeg_normalize_path "${candidate}")"; then
				continue
			fi
			if mcp_roots_contains "${attempt}"; then
				canonical="${attempt}"
				break
			fi
		done <<<"${MCP_ROOTS_PATHS}"

		if [ -z "${canonical}" ]; then
			mcp_fail -32602 "Access denied: ${user_path} is outside allowed roots"
		fi
	fi

	if [ "${mode}" = "read" ]; then
		if [ ! -f "${canonical}" ]; then
			mcp_fail -32602 "File not found: ${user_path}"
		fi
	else
		local parent
		parent="$(dirname "${canonical}")"
		if ! mcp_roots_contains "${parent}"; then
			mcp_fail -32602 "Access denied: ${parent} escapes allowed roots"
		fi
		if [ ! -d "${parent}" ]; then
			if ! mkdir -p "${parent}"; then
				mcp_fail -32603 "Unable to create parent directory: ${parent}"
			fi
		fi
	fi

	printf '%s' "${canonical}"
}
