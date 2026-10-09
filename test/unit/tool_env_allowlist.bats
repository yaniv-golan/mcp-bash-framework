#!/usr/bin/env bats
# Unit layer: MCPBASH_TOOL_ENV_ALLOWLIST name validation.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	PROJECT_ROOT="${BATS_TEST_TMPDIR}/proj"
	export MCPBASH_PROJECT_ROOT="${PROJECT_ROOT}"
	mkdir -p "${PROJECT_ROOT}/tools/echo-env" "${PROJECT_ROOT}/server.d"

	cat >"${PROJECT_ROOT}/server.d/server.meta.json" <<'EOF2'
{"name":"allowlist-test"}
EOF2

	cat >"${PROJECT_ROOT}/tools/echo-env/tool.meta.json" <<'EOF2'
{
  "name": "echo-env",
  "description": "Echo allowlisted variables",
  "inputSchema": { "type": "object" }
}
EOF2

	cat >"${PROJECT_ROOT}/tools/echo-env/tool.sh" <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
mcp_emit_json "$(mcp_json_obj message "FOO=${FOO:-blocked} X=${X:-blocked}")"
EOF2
	chmod +x "${PROJECT_ROOT}/tools/echo-env/tool.sh"
}

@test "tool_env_allowlist: names with array subscripts are not evaluated" {
	local marker="${BATS_TEST_TMPDIR}/pwned"
	FOO="ok" MCPBASH_TOOL_ENV_MODE="allowlist" \
		MCPBASH_TOOL_ENV_ALLOWLIST="FOO,xx[\$(touch\${IFS}${marker})]" \
		run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --allow-self
	assert_success
	assert_output --partial "FOO=ok"
	[ ! -e "${marker}" ]
}

@test "tool_env_allowlist: one-letter names pass through" {
	X="single" MCPBASH_TOOL_ENV_MODE="allowlist" MCPBASH_TOOL_ENV_ALLOWLIST="X" \
		run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --allow-self
	assert_success
	assert_output --partial "X=single"
}

@test "tool_env_allowlist: inherit set by policy.sh still requires INHERIT_ALLOW" {
	cat >"${PROJECT_ROOT}/server.d/policy.sh" <<'EOF2'
export MCPBASH_TOOL_ENV_MODE=inherit
EOF2
	FOO="host-secret" run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --allow-self
	assert_failure
	refute_output --partial "FOO=host-secret"
}

@test "tool_env_allowlist: inherit set by policy.sh works when the operator allows it" {
	cat >"${PROJECT_ROOT}/server.d/policy.sh" <<'EOF2'
export MCPBASH_TOOL_ENV_MODE=inherit
EOF2
	FOO="host-secret" MCPBASH_TOOL_ENV_INHERIT_ALLOW=true \
		run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --allow-self
	assert_success
	assert_output --partial "FOO=host-secret"
}
