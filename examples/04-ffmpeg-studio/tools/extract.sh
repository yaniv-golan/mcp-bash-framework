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
	printf 'mcp: SDK helpers not found (expected %s/tool-sdk.sh)\n' "${MCP_SDK:-<unset>}" >&2
	exit 1
fi

# shellcheck source=../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK}/tool-sdk.sh"

if [ $# -ne 3 ]; then
	mcp_tool_error -32602 "Missing required arguments: input, time, output"
	exit 1
fi

FFMPEG_STUDIO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/fs_guard.sh disable=SC1091
source "${FFMPEG_STUDIO_ROOT}/lib/fs_guard.sh"

if ! mcp_ffmpeg_guard_init "${FFMPEG_STUDIO_ROOT}"; then
	mcp_tool_error -32603 "Media guard initialization failed"
	exit 1
fi

input_path="$1"
timestamp="$2"
output_path="$3"

if ! full_input="$(mcp_ffmpeg_guard_read_path "${input_path}")"; then
	mcp_tool_error -32602 "Access denied: ${input_path} is outside configured media roots"
	exit 1
fi

if ! full_output="$(mcp_ffmpeg_guard_write_path "${output_path}")"; then
	mcp_tool_error -32602 "Access denied: ${output_path} is outside configured media roots"
	exit 1
fi

if [ ! -f "${full_input}" ]; then
	mcp_tool_error -32602 "Input file not found"
	exit 1
fi

# Run ffmpeg to extract single frame
if ffmpeg -ss "${timestamp}" -i "${full_input}" -frames:v 1 -y "${full_output}" >/dev/null 2>&1; then
	mcp_emit_text "Frame extracted to ${output_path}"
else
	mcp_tool_error -32603 "Failed to extract frame"
	exit 1
fi
