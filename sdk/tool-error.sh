#!/usr/bin/env bash
# Shared builder for tool error results (CallToolResult with isError: true).
#
# Used by tools (through the tool SDK) and by the server itself, e.g. for
# policy denials, so every error a client sees has the same shape:
#
#   {"content":[{"type":"text","text":"MSG\n\nHint: HINT"}],
#    "isError":true,
#    "_meta":{"mcpbash/error":{"type":"TYPE","message":"MSG","hint":"HINT","data":DATA}}}
#
# - The text block carries what the model needs: the message, plus the hint
#   when there is one.
# - There is no structuredContent: an error is not the tool's structured
#   output, and must not be checked against its outputSchema.
# - "hint" and "data" are left out of _meta when not given.
#
# Self-contained on purpose: no dependency on lib/ or on the rest of the SDK,
# and it works without jq (builtins only), down to bash 3.2.

# Documented error types. Other strings are accepted.
#   invalid_args not_found permission policy_denied timeout unavailable internal

# Quote a value as a JSON string literal.
__mcp_tool_error_json_string() {
	local value="${1-}"
	local json_bin="${MCPBASH_JSON_TOOL_BIN:-}"
	if [ -z "${json_bin}" ] && command -v jq >/dev/null 2>&1; then
		json_bin="jq"
	fi
	if [ -n "${json_bin}" ] && command -v "${json_bin}" >/dev/null 2>&1; then
		# On stdin, not as an argument: no argv size limit.
		printf '%s' "${value}" | "${json_bin}" -R -s '.'
		return 0
	fi
	# Builtins only: backslash and quote first, then every control character.
	local escaped="${value//\\/\\\\}"
	escaped="${escaped//\"/\\\"}"
	escaped="${escaped//$'\n'/\\n}"
	escaped="${escaped//$'\r'/\\r}"
	escaped="${escaped//$'\t'/\\t}"
	local code ch hex
	for code in 1 2 3 4 5 6 7 8 11 12 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
		printf -v hex '%02x' "${code}"
		# shellcheck disable=SC2059  # the format string is the escape being built
		printf -v ch "\\x${hex}"
		case "${escaped}" in
		*"${ch}"*) escaped="${escaped//"${ch}"/\\u00${hex}}" ;;
		esac
	done
	printf '"%s"' "${escaped}"
}

# mcp_tool_error_result TYPE MESSAGE [--hint TEXT] [--data JSON]
# Prints one CallToolResult (single line) and returns 0.
# --data must be JSON. With jq it is validated and dropped if invalid; without
# a JSON tool it is passed through as given.
mcp_tool_error_result() {
	local type="${1:-internal}"
	local message="${2-}"
	[ -n "${type}" ] || type="internal"
	shift 2 2>/dev/null || shift $#
	local hint="" data="" have_hint=0 have_data=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--hint)
			hint="${2-}"
			have_hint=1
			shift 2 2>/dev/null || shift $#
			;;
		--data)
			data="${2-}"
			have_data=1
			shift 2 2>/dev/null || shift $#
			;;
		*)
			shift
			;;
		esac
	done

	local json_bin="${MCPBASH_JSON_TOOL_BIN:-}"
	if [ -z "${json_bin}" ] && command -v jq >/dev/null 2>&1; then
		json_bin="jq"
	fi
	if [ "${have_data}" -eq 1 ]; then
		if [ -z "${data}" ]; then
			have_data=0
		elif [ -n "${json_bin}" ] && command -v "${json_bin}" >/dev/null 2>&1; then
			if ! data="$(printf '%s' "${data}" | "${json_bin}" -c '.' 2>/dev/null)" || [ -z "${data}" ]; then
				have_data=0
			fi
		fi
	fi

	local text="${message}"
	if [ "${have_hint}" -eq 1 ] && [ -n "${hint}" ]; then
		text="${message}"$'\n\n'"Hint: ${hint}"
	else
		have_hint=0
	fi

	local detail
	detail="\"type\":$(__mcp_tool_error_json_string "${type}"),\"message\":$(__mcp_tool_error_json_string "${message}")"
	if [ "${have_hint}" -eq 1 ]; then
		detail="${detail},\"hint\":$(__mcp_tool_error_json_string "${hint}")"
	fi
	if [ "${have_data}" -eq 1 ]; then
		detail="${detail},\"data\":${data}"
	fi
	printf '{"content":[{"type":"text","text":%s}],"isError":true,"_meta":{"mcpbash/error":{%s}}}' \
		"$(__mcp_tool_error_json_string "${text}")" "${detail}"
	return 0
}
