#!/usr/bin/env bats
# Unit tests for the tool-level policy hook.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/tools_policy.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/tools_policy.sh"
	# shellcheck source=lib/tools.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/tools.sh"

	MCPBASH_SERVER_DIR="${BATS_TEST_TMPDIR}/server.d"
	mkdir -p "${MCPBASH_SERVER_DIR}"
}

@test "tools_policy: the built-in policy allows an allowlisted tool when no policy.sh exists" {
	MCP_TOOLS_POLICY_LOADED="false"
	mcp_tools_policy_init
	MCPBASH_TOOL_ALLOWLIST="demo" run mcp_tools_policy_enforce "demo" '{}' '{}'
	assert_success
	MCPBASH_TOOL_ALLOWLIST="" MCPBASH_TOOL_ALLOW_DEFAULT="" run mcp_tools_policy_enforce "demo" '{}' '{}'
	assert_failure
}

@test "tools_policy: the project hook restricts, with its stdout as the reason" {
	cat <<'POLICY' >"${MCPBASH_SERVER_DIR}/policy.sh"
mcp_tools_policy_project() {
	[ "$1" != "blocked" ] && return 0
	printf 'blocked by project policy'
	return 1
}
POLICY
	MCP_TOOLS_POLICY_LOADED="false"
	mcp_tools_policy_init
	MCPBASH_TOOL_ALLOWLIST="*"
	mcp_tools_policy_enforce "ok" '{}' '{}'
	if mcp_tools_policy_enforce "blocked" '{}' '{}'; then
		fail "the project hook did not deny"
	fi
	assert_equal "${_MCP_TOOLS_ERROR_MESSAGE}" "blocked by project policy"
}

@test "tools_policy: a policy.sh with the 1.x hook fails closed, even for an allowlisted tool" {
	cat <<'POLICY' >"${MCPBASH_SERVER_DIR}/policy.sh"
mcp_tools_policy_check() {
	return 0
}
POLICY
	MCP_TOOLS_POLICY_LOADED="false"
	mcp_tools_policy_init
	MCPBASH_TOOL_ALLOWLIST="*"
	if mcp_tools_policy_enforce "demo" '{}' '{}'; then
		fail "the 1.x hook did not fail closed"
	fi
	assert_equal "${MCP_TOOLS_POLICY_LEGACY_HOOK}" "true"
	run mcp_tools_policy_file_has_legacy_hook "${MCPBASH_SERVER_DIR}/policy.sh"
	assert_success
}

@test "tools_policy: the static check ignores comments and the _default name" {
	printf '%s\n' '# mcp_tools_policy_check() was the 1.x hook' 'mcp_tools_policy_project() { mcp_tools_policy_check_default "$@"; }' >"${MCPBASH_SERVER_DIR}/policy.sh"
	run mcp_tools_policy_file_has_legacy_hook "${MCPBASH_SERVER_DIR}/policy.sh"
	assert_failure
	printf '%s\n' 'function mcp_tools_policy_check { :; }' >"${MCPBASH_SERVER_DIR}/policy.sh"
	run mcp_tools_policy_file_has_legacy_hook "${MCPBASH_SERVER_DIR}/policy.sh"
	assert_success
}

@test "tools_policy: list and call read the allowlist the same way (newlines, blanks)" {
	MCP_TOOLS_POLICY_LOADED="false"
	mcp_tools_policy_init
	MCPBASH_TOOL_ALLOWLIST=$'hello\nsecret'
	mcp_tools_policy_allowlist_effective
	assert_equal "${MCP_TOOLS_ALLOWLIST_NAMES}" "hello secret"
	mcp_tools_policy_enforce "hello" '{}' '{}'
	mcp_tools_policy_enforce "secret" '{}' '{}'
	if mcp_tools_policy_enforce "other" '{}' '{}'; then fail "other allowed"; fi
	# A list of blanks allows nothing, and denies cleanly (it crashed on 3.2).
	MCPBASH_TOOL_ALLOWLIST=" "
	run mcp_tools_policy_enforce "hello" '{}' '{}'
	assert_failure
	MCPBASH_TOOL_ALLOWLIST=$'\n ,'
	run mcp_tools_policy_enforce "hello" '{}' '{}'
	assert_failure
}

@test "tools_policy: an allowlist entry matches one tool name exactly" {
	MCP_TOOLS_POLICY_LOADED="false"
	mcp_tools_policy_init
	MCPBASH_TOOL_ALLOWLIST="a b c d"
	# "b c" is not an entry, though the list contains that text.
	run mcp_tools_policy_enforce "b c" '{}' '{}'
	assert_failure
	mcp_tools_policy_enforce "b" '{}' '{}'
}
