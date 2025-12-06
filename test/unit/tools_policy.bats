#!/usr/bin/env bash
# Unit tests for the tool-level policy hook.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"
# shellcheck source=lib/tools_policy.sh
# shellcheck disable=SC1090
. "${REPO_ROOT}/lib/tools_policy.sh"
# shellcheck source=lib/tools.sh
# shellcheck disable=SC1090
. "${REPO_ROOT}/lib/tools.sh"

test_create_tmpdir

printf ' -> default policy allows when no override exists\n'
MCPBASH_SERVER_DIR="${TEST_TMPDIR}/server.d"
mkdir -p "${MCPBASH_SERVER_DIR}"
MCP_TOOLS_POLICY_LOADED="false"
mcp_tools_policy_init
if ! mcp_tools_policy_check "demo" '{"path":"tools/demo/tool.sh"}'; then
	test_fail "default policy should allow tool execution"
fi

printf ' -> server.d/policy.sh override can deny with error\n'
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
if mcp_tools_policy_check "blocked" '{"path":"tools/blocked/tool.sh"}'; then
	test_fail "policy override should deny blocked tool"
fi

printf ' -> policy can attach error data and non-default codes\n'
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
if mcp_tools_policy_check "auth" '{"path":"tools/auth/tool.sh"}'; then
	test_fail "policy override should deny auth tool"
fi
