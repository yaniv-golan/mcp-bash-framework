#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck source=../../../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"
# shellcheck source=../../lib/roots.sh disable=SC1091
source "${script_dir}/../../lib/roots.sh"

input_path="$(mcp_args_get '.input // empty' 2>/dev/null || true)"
timestamp="$(mcp_args_get '.time // empty' 2>/dev/null || true)"
output_path="$(mcp_args_get '.output // empty' 2>/dev/null || true)"

if [[ -z "${input_path}" ]] && [[ $# -ge 1 ]]; then
	input_path="$1"
fi
if [[ -z "${timestamp}" ]] && [[ $# -ge 2 ]]; then
	timestamp="$2"
fi
if [[ -z "${output_path}" ]] && [[ $# -ge 3 ]]; then
	output_path="$3"
fi

if [[ -z "${input_path}" ]] || [[ -z "${timestamp}" ]] || [[ -z "${output_path}" ]]; then
	mcp_fail_invalid_args "Missing required arguments: input, time, output"
fi

full_input="$(mcp_ffmpeg_resolve_path "${input_path}" "read")"
full_output="$(mcp_ffmpeg_resolve_path "${output_path}" "write")"

# Validation: Input exists → Tool Execution Error (LLM can choose a different file)
if [[ ! -f "${full_input}" ]]; then
	mcp_result_error "$(
		mcp_json_obj \
			error "Input file not found" \
			input "${input_path}" \
			hint "Check the file exists and is within allowed media roots"
	)"
fi

# Run ffmpeg to extract single frame (capture stderr for error reporting)
_stderr_file=$(mktemp)
trap 'rm -f "$_stderr_file"' EXIT

if ffmpeg -ss "${timestamp}" -i "${full_input}" -frames:v 1 -y "${full_output}" >/dev/null 2>"$_stderr_file"; then
	mcp_result_success "$(mcp_json_obj message "Frame extracted to ${output_path}")"
else
	_stderr=$(cat "$_stderr_file")
	mcp_fail -32603 "Failed to extract frame: ${_stderr:-unknown error}"
fi
