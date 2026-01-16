#!/usr/bin/env bash
set -euo pipefail

# Source SDK (MCP_SDK is set by the framework when running tools)
# shellcheck source=../../../../sdk/tool-sdk.sh disable=SC1091
source "${MCP_SDK:?MCP_SDK environment variable not set}/tool-sdk.sh"

json_tool="${MCPBASH_JSON_TOOL_BIN:-}"
if [[ -z "${json_tool}" ]] || ! command -v "${json_tool}" >/dev/null 2>&1; then
	json_tool=""
fi

path="$(mcp_args_get '.path // empty' 2>/dev/null || true)"
if [[ -z "${path}" ]] && [[ $# -ge 1 ]]; then
	path="$1"
fi

# ERROR HANDLING BEST PRACTICES:
# - Protocol Errors (-32xxx): For structural issues the LLM cannot fix
# - Tool Execution Errors (exit 1 with message): For correctable input issues
# See docs/ERRORS.md for full guidance.

# Missing required argument → Protocol Error (request structure issue)
if [[ -z "${path}" ]]; then
	mcp_fail_invalid_args "Missing required argument: path"
fi

# Enforce roots - path outside allowed roots → Tool Execution Error
# The LLM can self-correct by choosing a path within allowed roots
if ! mcp_roots_contains "${path}"; then
	roots_list="$(mcp_roots_list 2>/dev/null | head -3 | tr '\n' ', ' | sed 's/,$//')"
	mcp_error "permission_denied" "Path is outside allowed roots" \
		--hint "Try a path within: ${roots_list:-<no roots configured>}" \
		--data "$(mcp_json_obj path "${path}")"
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

# File not found → Tool Execution Error
# The LLM can self-correct by choosing a different file
if [[ ! -f "${full_path}" ]]; then
	mcp_error "not_found" "File not found" \
		--hint "Check the path exists and is a regular file" \
		--data "$(mcp_json_obj path "${path}")"
fi

content="$(cat "${full_path}")"
bytes="$(printf '%s' "${content}" | wc -c | tr -d ' ')"

if [[ -n "${json_tool}" ]]; then
	mcp_result_success "$("${json_tool}" -n \
		--arg path "${full_path}" \
		--arg content "${content}" \
		--argjson bytes "${bytes}" \
		'{path:$path, bytes:$bytes, content:$content}')" || mcp_result_success "$(mcp_json_obj content "${content}")"
else
	mcp_result_success "$(mcp_json_obj content "${content}")"
fi
