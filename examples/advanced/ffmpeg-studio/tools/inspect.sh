#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${MCP_SDK:-}" ] || [ ! -f "${MCP_SDK}/tool-sdk.sh" ]; then
	if fallback_sdk="$(cd "${script_dir}/../../../sdk" 2>/dev/null && pwd)"; then
		if [ -f "${fallback_sdk}/tool-sdk.sh" ]; then
			MCP_SDK="${fallback_sdk}"
		fi
	fi
fi

if [ -z "${MCP_SDK:-}" ] || [ ! -f "${MCP_SDK}/tool-sdk.sh" ]; then
	printf 'mcp: SDK helpers not found (set MCP_SDK to your framework sdk/ path or keep this example inside the framework repo; expected %s/tool-sdk.sh)\n' "${MCP_SDK:-<unset>}" >&2
	exit 1
fi

# shellcheck source=../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK}/tool-sdk.sh"

path="$(mcp_args_get '.path // empty' 2>/dev/null || true)"
if [ -z "${path}" ] && [ $# -ge 1 ]; then
	path="$1"
fi

if [ -z "${path}" ]; then
	mcp_fail_invalid_args "Missing required argument: path"
fi

FFMPEG_STUDIO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/fs_guard.sh disable=SC1091
source "${FFMPEG_STUDIO_ROOT}/lib/fs_guard.sh"

if ! mcp_ffmpeg_guard_init "${FFMPEG_STUDIO_ROOT}"; then
	mcp_fail -32603 "Media guard initialization failed"
fi

if ! full_path="$(mcp_ffmpeg_guard_read_path "${path}")"; then
	mcp_fail -32602 "Access denied: ${path} is outside configured media roots"
fi

# Validation: File exists
if [ ! -f "${full_path}" ]; then
	mcp_fail -32602 "File not found: ${path}"
fi

# Run ffprobe
if ! output=$(ffprobe -v quiet -print_format json -show_format -show_streams "${full_path}" 2>/dev/null); then
	mcp_fail -32603 "Failed to inspect media file: ${path}"
fi

mcp_emit_json "${output}"
