#!/usr/bin/env bash
# Root resolution helpers for ffmpeg-studio using MCP roots.

set -euo pipefail

FFMPEG_STUDIO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mcp_ffmpeg_normalize_path() {
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

mcp_ffmpeg_require_roots() {
	if [[ -n "${MCP_ROOTS_PATHS:-}" ]]; then
		return 0
	fi

	# Developer-friendly default: fall back to the example media folder so the
	# example works out of the box without configuring roots.
	local default_root
	default_root="$(mcp_ffmpeg_normalize_path "${FFMPEG_STUDIO_ROOT}/media")" || mcp_fail --type internal "Unable to resolve default media root"
	MCP_ROOTS_PATHS="${default_root}"
	# shellcheck disable=SC2034  # Exported for downstream MCP tools
	MCP_ROOTS_COUNT=1
	# shellcheck disable=SC2034  # Exported for downstream MCP tools
	MCP_ROOTS_JSON="[{\"uri\":\"file://${default_root}\",\"name\":\"Media\",\"path\":\"${default_root}\"}]"
}

mcp_ffmpeg_resolve_path() {
	local user_path="$1"
	local mode="${2:-read}" # read|write

	[[ -n "${user_path}" ]] || mcp_fail --type invalid_args "Path cannot be empty"

	mcp_ffmpeg_require_roots

	if [[ "${user_path}" == "~"* ]]; then
		user_path="${user_path/#\~/${HOME}}"
	fi
	if [[ "${user_path}" == ./* ]]; then
		user_path="${user_path#./}"
	fi

	local canonical=""

	if [[ "${user_path}" == /* ]]; then
		canonical="$(mcp_ffmpeg_normalize_path "${user_path}")" || mcp_fail --type internal "Unable to resolve path: ${user_path}"
		if ! mcp_roots_contains "${canonical}"; then
			mcp_fail --type invalid_args "Access denied: ${user_path} is outside allowed roots"
		fi
	else
		while IFS= read -r root; do
			[[ -n "${root}" ]] || continue
			local candidate="${user_path}"
			# If the path is already prefixed with the root folder name (e.g., "media/foo"),
			# trim it to avoid duplicating ("media/media/foo").
			local root_name="${root##*/}"
			if [[ "${candidate}" == "${root_name}/"* ]]; then
				candidate="${candidate#"${root_name}"/}"
			fi
			candidate="${root}/${candidate}"
			local attempt
			if ! attempt="$(mcp_ffmpeg_normalize_path "${candidate}")"; then
				continue
			fi
			if mcp_roots_contains "${attempt}"; then
				canonical="${attempt}"
				break
			fi
		done <<<"${MCP_ROOTS_PATHS}"

		if [[ -z "${canonical}" ]]; then
			mcp_fail --type invalid_args "Access denied: ${user_path} is outside allowed roots"
		fi
	fi

	if [[ "${mode}" == "read" ]]; then
		if [[ ! -f "${canonical}" ]]; then
			mcp_fail --type invalid_args "File not found: ${user_path}"
		fi
	else
		local parent
		parent="$(dirname "${canonical}")"
		if ! mcp_roots_contains "${parent}"; then
			mcp_fail --type invalid_args "Access denied: ${parent} escapes allowed roots"
		fi
		if [[ ! -d "${parent}" ]]; then
			if ! mkdir -p "${parent}"; then
				mcp_fail --type internal "Unable to create parent directory: ${parent}"
			fi
		fi
	fi

	printf '%s' "${canonical}"
}
