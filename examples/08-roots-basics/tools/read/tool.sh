#!/usr/bin/env bash
set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck source=../../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

json_tool="${MCPBASH_JSON_TOOL_BIN:-}"
if [ -z "${json_tool}" ] || ! command -v "${json_tool}" >/dev/null 2>&1; then
	json_tool=""
fi

path="$(mcp_args_get '.path // empty' 2>/dev/null || true)"
if [ -z "${path}" ] && [ $# -ge 1 ]; then
	path="$1"
fi
if [ -z "${path}" ]; then
	mcp_fail_invalid_args "Missing required argument: path"
fi

# Enforce roots
if ! mcp_roots_contains "${path}"; then
	mcp_fail -32602 "Path is outside allowed roots"
fi

# Resolve to absolute path for reading and messaging
if command -v realpath >/dev/null 2>&1; then
	full_path="$(realpath -m "${path}" 2>/dev/null || realpath "${path}" 2>/dev/null || printf '%s' "${path}")"
else
	if [[ "${path}" != /* ]]; then
		full_path="$(cd "$(dirname "${path}")" 2>/dev/null && pwd)/$(basename "${path}")"
	else
		full_path="${path}"
	fi
fi

if [ ! -f "${full_path}" ]; then
	mcp_fail -32602 "File not found: ${path}"
fi

content="$(cat "${full_path}")"
bytes="$(printf '%s' "${content}" | wc -c | tr -d ' ')"

if [ -n "${json_tool}" ]; then
	mcp_emit_json "$("${json_tool}" -n \
		--arg path "${full_path}" \
		--arg content "${content}" \
		--argjson bytes "${bytes}" \
		'{path:$path, bytes:$bytes, content:$content}')" || mcp_emit_text "${content}"
else
	mcp_emit_text "${content}"
fi
