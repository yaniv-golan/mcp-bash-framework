#!/usr/bin/env bats
# Unit layer: run-tool --with-server-env and --source options.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'
load '../common/ndjson'

setup() {
	PROJECT_ROOT="${BATS_TEST_TMPDIR}/proj"
	export MCPBASH_PROJECT_ROOT="${PROJECT_ROOT}"
	mkdir -p "${PROJECT_ROOT}/tools/echo-env" "${PROJECT_ROOT}/server.d" "${PROJECT_ROOT}/config"

	cat >"${PROJECT_ROOT}/server.d/server.meta.json" <<'EOF'
{"name":"source-test"}
EOF

	cat >"${PROJECT_ROOT}/tools/echo-env/tool.meta.json" <<'EOF'
{
  "name": "echo-env",
  "description": "Echo environment variables",
  "inputSchema": { "type": "object" }
}
EOF

	# Use MCPBASH_* prefixed variables which always pass through the tool env policy
	cat >"${PROJECT_ROOT}/tools/echo-env/tool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
mcp_emit_json "$(mcp_json_obj message "MCPBASH_TEST_FROM_SERVER_ENV=${MCPBASH_TEST_FROM_SERVER_ENV:-not-set} MCPBASH_CUSTOM_VAR=${MCPBASH_CUSTOM_VAR:-not-set} MCPBASH_OVERRIDE_VAR=${MCPBASH_OVERRIDE_VAR:-not-set} POLICY_VAR=${POLICY_VAR:-blocked}")"
EOF
	chmod +x "${PROJECT_ROOT}/tools/echo-env/tool.sh"
}

@test "run-tool: --with-server-env sources server.d/env.sh" {
	# Create env.sh that sets a test variable (MCPBASH_* prefix passes through tool env policy)
	cat >"${PROJECT_ROOT}/server.d/env.sh" <<'EOF'
export MCPBASH_TEST_FROM_SERVER_ENV="sourced-successfully"
EOF

	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --with-server-env
	assert_success
	assert_output --partial "sourced-successfully"
}

@test "run-tool: --with-server-env silently continues when env.sh absent" {
	# Don't create server.d/env.sh - it should silently continue
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --with-server-env
	assert_success
	assert_output --partial "not-set"
}

@test "run-tool: --source allows custom env file" {
	cat >"${PROJECT_ROOT}/config/custom.sh" <<'EOF'
export MCPBASH_CUSTOM_VAR="custom-value"
EOF

	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --source config/custom.sh
	assert_success
	assert_output --partial "custom-value"
}

@test "run-tool: --source with missing file fails" {
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --source nonexistent.sh
	assert_failure
	assert_output --partial "env file not found"
}

@test "run-tool: MCPBASH_RUN_TOOL_SOURCE_SERVER_ENV=1 enables implicit sourcing" {
	cat >"${PROJECT_ROOT}/server.d/env.sh" <<'EOF'
export MCPBASH_TEST_FROM_SERVER_ENV="via-env-var"
EOF

	MCPBASH_RUN_TOOL_SOURCE_SERVER_ENV=1 run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env
	assert_success
	assert_output --partial "via-env-var"
}

@test "run-tool: --source with syntax error shows clear error" {
	# Create a file with syntax error
	cat >"${PROJECT_ROOT}/bad-syntax.sh" <<'EOF'
export GOOD_VAR="ok"
if [[ missing bracket
EOF

	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --source bad-syntax.sh 2>&1
	assert_failure
	# Shell should report syntax error
	assert_output --partial "syntax error"
}

@test "run-tool: later --source files override earlier ones" {
	# Base config (MCPBASH_* prefix passes through tool env policy)
	cat >"${PROJECT_ROOT}/config/base.sh" <<'EOF'
export MCPBASH_OVERRIDE_VAR="base-value"
EOF

	# Override config
	cat >"${PROJECT_ROOT}/config/override.sh" <<'EOF'
export MCPBASH_OVERRIDE_VAR="override-value"
EOF

	# Later --source should override earlier
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --source config/base.sh --source config/override.sh
	assert_success
	assert_output --partial "override-value"
}

@test "run-tool: --print-env shows WILL_SOURCE_SERVER_ENV without executing" {
	# Create env.sh that would set a variable if sourced
	cat >"${PROJECT_ROOT}/server.d/env.sh" <<'EOF'
export SHOULD_NOT_BE_SET="if-this-is-set-sourcing-happened"
EOF

	# --print-env should show WILL_SOURCE_SERVER_ENV but NOT actually source it
	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --with-server-env --print-env
	assert_success
	assert_output --partial "WILL_SOURCE_SERVER_ENV="
	assert_output --partial "server.d/env.sh"
	# The env var should NOT be set (not sourced, just reported)
	refute_output --partial "SHOULD_NOT_BE_SET"
}

@test "run-tool: --print-env shows WILL_SOURCE for --source files" {
	echo 'export FOO=bar' >"${PROJECT_ROOT}/config/test.sh"

	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --source config/test.sh --print-env
	assert_success
	assert_output --partial "WILL_SOURCE[0]="
	assert_output --partial "config/test.sh"
}

@test "run-tool: --verbose shows sourced file names" {
	cat >"${PROJECT_ROOT}/server.d/env.sh" <<'EOF'
export MCPBASH_VERBOSE_TEST="set"
EOF

	run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --with-server-env --verbose 2>&1
	assert_success
	assert_output --partial "run-tool: sourcing"
	assert_output --partial "server.d/env.sh"
}

@test "run-tool: sourced env vars affect MCPBASH_TOOL_ENV_ALLOWLIST policy" {
	# Create a tool that checks policy passthrough
	cat >"${PROJECT_ROOT}/tools/echo-env/tool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
mcp_emit_json "$(mcp_json_obj message "POLICY_VAR=${POLICY_VAR:-blocked}")"
EOF
	chmod +x "${PROJECT_ROOT}/tools/echo-env/tool.sh"

	# server.d/env.sh configures allowlist mode with a specific var
	cat >"${PROJECT_ROOT}/server.d/env.sh" <<'EOF'
export MCPBASH_TOOL_ENV_MODE="allowlist"
export MCPBASH_TOOL_ENV_ALLOWLIST="POLICY_VAR"
EOF

	# Without --with-server-env, the allowlist isn't set, so POLICY_VAR doesn't pass through
	POLICY_VAR="should-be-blocked" run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env
	assert_success
	assert_output --partial "blocked"

	# With --with-server-env, the allowlist IS set, so POLICY_VAR passes through
	POLICY_VAR="passed-through" run "${MCPBASH_HOME}/bin/mcp-bash" run-tool echo-env --with-server-env
	assert_success
	assert_output --partial "passed-through"
}
