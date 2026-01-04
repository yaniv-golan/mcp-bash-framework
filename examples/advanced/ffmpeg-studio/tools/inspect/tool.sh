#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck source=../../../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"
# shellcheck source=../../lib/roots.sh disable=SC1091
source "${script_dir}/../../lib/roots.sh"

json_bin="${MCPBASH_JSON_TOOL_BIN:-}"
if [[ -z "${json_bin}" ]] || ! command -v "${json_bin}" >/dev/null 2>&1; then
	mcp_fail -32603 "JSON tooling unavailable for argument parsing"
fi

path="$(mcp_args_get '.path // empty' 2>/dev/null || true)"
if [[ -z "${path}" ]] && [[ $# -ge 1 ]]; then
	path="$1"
fi

# Accept bare-string arguments (some clients may send the path as a string instead of an object).
if [[ -z "${path}" ]] && [[ -n "${json_bin}" ]]; then
	raw_args="$(mcp_args_raw)"
	if [[ -n "${raw_args}" ]]; then
		path="$("${json_bin}" -r 'if type=="string" then . elif type=="object" then .path // empty else empty end' <<<"${raw_args}" 2>/dev/null || true)"
	fi
fi

if [[ -z "${path}" ]]; then
	mcp_fail_invalid_args "Missing required argument: path"
fi

full_path="$(mcp_ffmpeg_resolve_path "${path}" "read")"

# Validation: File exists → Tool Execution Error (LLM can choose a different file)
if [[ ! -f "${full_path}" ]]; then
	mcp_result_error "$(
		mcp_json_obj \
			error "File not found" \
			path "${path}" \
			hint "Check the file exists and is within allowed media roots"
	)"
fi

# Run ffprobe (capture stderr for error reporting)
_stderr_file=$(mktemp)
trap 'rm -f "$_stderr_file"' EXIT

if output=$(ffprobe -v quiet -print_format json -show_format -show_streams "${full_path}" 2>"$_stderr_file"); then
	mcp_result_success "${output}"
else
	_stderr=$(cat "$_stderr_file")
	mcp_fail -32603 "Failed to inspect media file: ${_stderr:-unknown error}"
fi
