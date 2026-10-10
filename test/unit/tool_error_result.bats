#!/usr/bin/env bats
# Unit: mcp_tool_error_result builds the shared isError CallToolResult used by
# mcp_fail --type and by server-side policy denials.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	command -v jq >/dev/null 2>&1 || skip "jq needed to check the output"
	JQ="$(command -v jq)"
	TRICKY=$'line one "quoted"\nback\\slash\ttab end'
}

# Build with jq available.
build_jq() {
	MCPBASH_JSON_TOOL_BIN="${JQ}" bash -c '. "$1/sdk/tool-error.sh"; shift; mcp_tool_error_result "$@"' _ "${MCPBASH_HOME}" "$@"
}

# Build with no JSON tool at all (PATH emptied, builtins only).
build_minimal() {
	MCPBASH_JSON_TOOL_BIN="" PATH="" "${BASH}" -c '. "$1/sdk/tool-error.sh"; shift; mcp_tool_error_result "$@"' _ "${MCPBASH_HOME}" "$@"
}

check_shape() {
	local out="$1" type="$2" msg="$3" hint="${4-}"
	assert_equal "$(printf '%s' "${out}" | "${JQ}" -r '.isError')" "true"
	assert_equal "$(printf '%s' "${out}" | "${JQ}" -r 'has("structuredContent")')" "false"
	assert_equal "$(printf '%s' "${out}" | "${JQ}" -r '.content[0].type')" "text"
	assert_equal "$(printf '%s' "${out}" | "${JQ}" -r '._meta["mcpbash/error"].type')" "${type}"
	assert_equal "$(printf '%s' "${out}" | "${JQ}" -r '._meta["mcpbash/error"].message')" "${msg}"
	if [ -n "${hint}" ]; then
		assert_equal "$(printf '%s' "${out}" | "${JQ}" -r '.content[0].text')" "${msg}"$'\n\n'"Hint: ${hint}"
		assert_equal "$(printf '%s' "${out}" | "${JQ}" -r '._meta["mcpbash/error"].hint')" "${hint}"
	else
		assert_equal "$(printf '%s' "${out}" | "${JQ}" -r '.content[0].text')" "${msg}"
		assert_equal "$(printf '%s' "${out}" | "${JQ}" -r '._meta["mcpbash/error"] | has("hint")')" "false"
	fi
}

@test "tool_error: message only (jq)" {
	out="$(build_jq not_found "No such ticket")"
	check_shape "${out}" not_found "No such ticket"
	assert_equal "$(printf '%s' "${out}" | "${JQ}" -r '._meta["mcpbash/error"] | has("data")')" "false"
}

@test "tool_error: hint and data (jq)" {
	out="$(build_jq invalid_args "limit must be positive" --hint "pass 1-100" --data '{"field":"limit","got":-1}')"
	check_shape "${out}" invalid_args "limit must be positive" "pass 1-100"
	assert_equal "$(printf '%s' "${out}" | "${JQ}" -c '._meta["mcpbash/error"].data')" '{"field":"limit","got":-1}'
}

@test "tool_error: newline, quotes, backslash and tab survive (jq)" {
	out="$(build_jq internal "${TRICKY}" --hint "${TRICKY}")"
	check_shape "${out}" internal "${TRICKY}" "${TRICKY}"
}

@test "tool_error: newline, quotes, backslash and tab survive (no JSON tool)" {
	out="$(build_minimal internal "${TRICKY}" --hint "${TRICKY}")"
	check_shape "${out}" internal "${TRICKY}" "${TRICKY}"
}

@test "tool_error: other control characters are escaped (no JSON tool)" {
	msg=$'bell\a esc\033 nul-free'
	out="$(build_minimal internal "${msg}")"
	check_shape "${out}" internal "${msg}"
}

@test "tool_error: valid --data is kept without a JSON tool" {
	out="$(build_minimal unavailable "down" --data '{"retryAfter":30}')"
	check_shape "${out}" unavailable "down"
	assert_equal "$(printf '%s' "${out}" | "${JQ}" -c '._meta["mcpbash/error"].data')" '{"retryAfter":30}'
}

@test "tool_error: invalid --data is dropped, output stays valid JSON (jq)" {
	out="$(build_jq internal "boom" --data '{not json')"
	check_shape "${out}" internal "boom"
	assert_equal "$(printf '%s' "${out}" | "${JQ}" -r '._meta["mcpbash/error"] | has("data")')" "false"
}

@test "tool_error: empty type defaults to internal, output is one line" {
	out="$(build_jq "" "boom")"
	check_shape "${out}" internal "boom"
	assert_equal "$(printf '%s\n' "${out}" | wc -l | tr -d ' ')" "1"
}

@test "tool_error: works under bash 3.2 when available" {
	[ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -eq 3 ]' || skip "no bash 3.2 at /bin/bash"
	out="$(MCPBASH_JSON_TOOL_BIN="" PATH="" /bin/bash -c '. "$1/sdk/tool-error.sh"; mcp_tool_error_result internal "$2" --hint "$2"' _ "${MCPBASH_HOME}" "${TRICKY}")"
	check_shape "${out}" internal "${TRICKY}" "${TRICKY}"
	msg=$'bell\a esc\033 unit\x1f end'
	out="$(MCPBASH_JSON_TOOL_BIN="" PATH="" /bin/bash -c '. "$1/sdk/tool-error.sh"; mcp_tool_error_result internal "$2"' _ "${MCPBASH_HOME}" "${msg}")"
	check_shape "${out}" internal "${msg}"
}
