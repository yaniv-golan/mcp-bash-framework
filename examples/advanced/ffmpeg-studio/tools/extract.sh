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
# shellcheck source=../lib/roots.sh disable=SC1091
source "${script_dir}/../lib/roots.sh"

input_path="$(mcp_args_get '.input // empty' 2>/dev/null || true)"
timestamp="$(mcp_args_get '.time // empty' 2>/dev/null || true)"
output_path="$(mcp_args_get '.output // empty' 2>/dev/null || true)"

if [ -z "${input_path}" ] && [ $# -ge 1 ]; then
	input_path="$1"
fi
if [ -z "${timestamp}" ] && [ $# -ge 2 ]; then
	timestamp="$2"
fi
if [ -z "${output_path}" ] && [ $# -ge 3 ]; then
	output_path="$3"
fi

if [ -z "${input_path}" ] || [ -z "${timestamp}" ] || [ -z "${output_path}" ]; then
	mcp_fail_invalid_args "Missing required arguments: input, time, output"
fi

full_input="$(ffmpeg_resolve_path "${input_path}" "read")"
full_output="$(ffmpeg_resolve_path "${output_path}" "write")"

if [ ! -f "${full_input}" ]; then
	mcp_fail -32602 "Input file not found: ${input_path}"
fi

# Run ffmpeg to extract single frame
if ffmpeg -ss "${timestamp}" -i "${full_input}" -frames:v 1 -y "${full_output}" >/dev/null 2>&1; then
	json_tool="${MCPBASH_JSON_TOOL_BIN:-}"
	if [ -z "${json_tool}" ] || ! command -v "${json_tool}" >/dev/null 2>&1; then
		json_tool=""
	fi

	if [ -n "${json_tool}" ]; then
		mcp_emit_json "$("${json_tool}" -n --arg message "Frame extracted to ${output_path}" '{message:$message}')" || mcp_emit_text "Frame extracted to ${output_path}"
	else
		mcp_emit_text "Frame extracted to ${output_path}"
	fi
else
	mcp_fail -32603 "Failed to extract frame"
fi
