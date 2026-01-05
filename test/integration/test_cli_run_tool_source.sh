#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="run-tool --with-server-env and --source source env files before execution"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"
# shellcheck source=../common/fixtures.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/fixtures.sh"

test_create_tmpdir

# Create a minimal project with server.d/env.sh
PROJECT="${TEST_TMPDIR}/test-project"
mkdir -p "${PROJECT}/server.d" "${PROJECT}/tools/echo-env"

cat >"${PROJECT}/server.d/server.meta.json" <<'EOF'
{"name": "test-source"}
EOF

cat >"${PROJECT}/server.d/env.sh" <<'EOF'
export MCPBASH_INTEGRATION_TEST_VAR="from-server-env"
export MCPBASH_TOOL_ENV_MODE="allowlist"
export MCPBASH_TOOL_ENV_ALLOWLIST="POLICY_TEST_VAR"
EOF

cat >"${PROJECT}/tools/echo-env/tool.meta.json" <<'EOF'
{"name": "echo-env", "description": "Echo environment variables"}
EOF

# Use MCPBASH_* prefixed variables which always pass through the tool env policy
cat >"${PROJECT}/tools/echo-env/tool.sh" <<'EOF'
#!/usr/bin/env bash
source "${MCP_SDK}/tool-sdk.sh"
mcp_emit_json "$(mcp_json_obj message "MCPBASH_INTEGRATION_TEST_VAR=${MCPBASH_INTEGRATION_TEST_VAR:-not-set} POLICY_TEST_VAR=${POLICY_TEST_VAR:-blocked}")"
EOF
chmod +x "${PROJECT}/tools/echo-env/tool.sh"

# Test 1: --with-server-env sources server.d/env.sh
printf ' -> --with-server-env sources server.d/env.sh\n'
output=$(mcp-bash run-tool echo-env --project-root "${PROJECT}" --with-server-env --allow-self 2>&1)
if ! printf '%s' "${output}" | grep -q "from-server-env"; then
	test_fail "Expected 'from-server-env' in output, got: ${output}"
fi

# Test 2: Policy passthrough works with --with-server-env
printf ' -> Policy passthrough with --with-server-env\n'
output=$(POLICY_TEST_VAR="passed-through" mcp-bash run-tool echo-env --project-root "${PROJECT}" --with-server-env --allow-self 2>&1)
if ! printf '%s' "${output}" | grep -q "passed-through"; then
	test_fail "Expected 'passed-through' in output, got: ${output}"
fi

# Test 3: Without --with-server-env, policy var is blocked
printf ' -> Without --with-server-env, policy var blocked\n'
output=$(POLICY_TEST_VAR="should-be-blocked" mcp-bash run-tool echo-env --project-root "${PROJECT}" --allow-self 2>&1)
if ! printf '%s' "${output}" | grep -q "blocked"; then
	test_fail "Expected 'blocked' in output, got: ${output}"
fi

# Test 4: --source with custom file
printf ' -> --source with custom env file\n'
mkdir -p "${PROJECT}/config"
cat >"${PROJECT}/config/custom.sh" <<'EOF'
export MCPBASH_INTEGRATION_TEST_VAR="from-custom-source"
EOF
output=$(mcp-bash run-tool echo-env --project-root "${PROJECT}" --source config/custom.sh --allow-self 2>&1)
if ! printf '%s' "${output}" | grep -q "from-custom-source"; then
	test_fail "Expected 'from-custom-source' in output, got: ${output}"
fi

# Test 5: --source with missing file fails
printf ' -> --source with missing file fails\n'
if output=$(mcp-bash run-tool echo-env --project-root "${PROJECT}" --source missing.sh --allow-self 2>&1); then
	test_fail "Expected failure for missing --source file"
fi
if ! printf '%s' "${output}" | grep -q "env file not found"; then
	test_fail "Expected 'env file not found' error, got: ${output}"
fi

# Test 6: MCPBASH_RUN_TOOL_SOURCE_SERVER_ENV=1 works
printf ' -> MCPBASH_RUN_TOOL_SOURCE_SERVER_ENV=1 implicit sourcing\n'
output=$(MCPBASH_RUN_TOOL_SOURCE_SERVER_ENV=1 mcp-bash run-tool echo-env --project-root "${PROJECT}" --allow-self 2>&1)
if ! printf '%s' "${output}" | grep -q "from-server-env"; then
	test_fail "Expected 'from-server-env' with env var trigger, got: ${output}"
fi

test_cleanup_tmpdir
printf 'All --with-server-env and --source tests passed.\n'
