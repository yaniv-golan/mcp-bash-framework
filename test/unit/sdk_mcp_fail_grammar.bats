#!/usr/bin/env bats
# Unit layer: the mcp_fail grammar (2.0): --type optional, "--" for a literal
# message, the removed numeric form, and arguments it can't use.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

# fail_run ARGS...: run mcp_fail with ARGS outside the framework; the result
# goes to stdout, notes to stderr.
fail_run() {
	MCPBASH_JSON_TOOL_BIN="${JQ:-jq}" "${BASH}" -c '. "${MCPBASH_HOME}/sdk/tool-sdk.sh" >/dev/null 2>&1; mcp_fail "$@"' _ "$@"
}

# shape: [type, text] of the result on the first line of ${output}
shape() {
	printf '%s\n' "${output}" | head -n 1 | "${JQ:-jq}" -c '[._meta["mcpbash/error"].type, .content[0].text]'
}

@test "mcp_fail grammar: a message alone has type tool_failed" {
	run --separate-stderr fail_run "not found"
	assert_failure
	assert_equal "$(shape)" '["tool_failed","not found"]'
	assert_equal "${stderr}" "not found"
}

@test "mcp_fail grammar: a numeric message alone is a message" {
	run --separate-stderr fail_run 42
	assert_equal "$(shape)" '["tool_failed","42"]'
	run --separate-stderr fail_run 404 --hint "check the id"
	assert_equal "$(shape)" $'["tool_failed","404\\n\\nHint: check the id"]'
}

@test "mcp_fail grammar: -- takes the next argument literally" {
	run --separate-stderr fail_run -- "--type"
	assert_equal "$(shape)" '["tool_failed","--type"]'
}

@test "mcp_fail grammar: the numeric form ends with its message and a removal note" {
	run --separate-stderr fail_run -32602 "bad args"
	assert_failure
	assert_equal "$(shape)" '["invalid_args","bad args"]'
	[[ "${stderr}" == *"removed in mcp-bash 2.0"* ]]
	run --separate-stderr fail_run 404 "gone"
	assert_equal "$(shape)" '["tool_failed","gone"]'
	[[ "${stderr}" == *"removed in mcp-bash 2.0"* ]]
}

@test "mcp_fail grammar: extra arguments after the message are reported, not silently dropped" {
	run --separate-stderr fail_run "not found" "details"
	assert_failure
	assert_equal "$(shape)" '["tool_failed","not found"]'
	[[ "${stderr}" == *"ignored"* ]] || fail "no note on stderr: ${stderr}"
}

@test "mcp_fail grammar: no arguments" {
	run --separate-stderr fail_run
	assert_failure
	assert_equal "$(shape)" '["tool_failed","Tool failed"]'
}
