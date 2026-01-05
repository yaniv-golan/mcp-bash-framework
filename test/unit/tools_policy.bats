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

@test "tools_policy: default policy allows when no override exists" {
	MCP_TOOLS_POLICY_LOADED="false"
	mcp_tools_policy_init

	run mcp_tools_policy_check "demo" '{"path":"tools/demo/tool.sh"}'
	assert_success
}

@test "tools_policy: server.d/policy.sh override can deny with error" {
	cat <<'POLICY' >"${MCPBASH_SERVER_DIR}/policy.sh"
mcp_tools_policy_check() {
	local tool_name="$1"
	if [ "${tool_name}" = "blocked" ]; then
		mcp_tools_error -32602 "blocked by policy"
		return 1
	fi
	return 0
}
POLICY
	MCP_TOOLS_POLICY_LOADED="false"
	mcp_tools_policy_init

	run mcp_tools_policy_check "blocked" '{"path":"tools/blocked/tool.sh"}'
	assert_failure
}

@test "tools_policy: policy can attach error data and non-default codes" {
	cat <<'POLICY' >"${MCPBASH_SERVER_DIR}/policy.sh"
mcp_tools_policy_check() {
	local tool_name="$1"
	if [ "${tool_name}" = "auth" ]; then
		mcp_tools_error -32600 "auth required" '{"reason":"auth"}'
		return 1
	fi
	return 0
}
POLICY
	MCP_TOOLS_POLICY_LOADED="false"
	mcp_tools_policy_init

	run mcp_tools_policy_check "auth" '{"path":"tools/auth/tool.sh"}'
	assert_failure
}
