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

path="$(mcp_args_get '.path // empty' 2>/dev/null || true)"
if [ -z "${path}" ] && [ $# -ge 1 ]; then
	path="$1"
fi

# Accept bare-string arguments (some clients may send the path as a string instead of an object).
if [ -z "${path}" ]; then
	raw_args="$(mcp_args_raw)"
	if [ -n "${raw_args}" ]; then
		path="$(printf '%s' "${raw_args}" | jq -r 'if type=="string" then . elif type=="object" then .path // empty else empty end' 2>/dev/null || true)"
	fi
fi

if [ -z "${path}" ]; then
	mcp_fail_invalid_args "Missing required argument: path"
fi

full_path="$(ffmpeg_resolve_path "${path}" "read")"

# Validation: File exists
if [ ! -f "${full_path}" ]; then
	mcp_fail -32602 "File not found: ${path}"
fi

# Run ffprobe
if ! output=$(ffprobe -v quiet -print_format json -show_format -show_streams "${full_path}" 2>/dev/null); then
	mcp_fail -32603 "Failed to inspect media file: ${path}"
fi

mcp_emit_json "${output}"
