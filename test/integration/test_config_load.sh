#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="SDK mcp_config_load and mcp_config_get helpers."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

run_server() {
	local project_root="$1"
	local request_file="$2"
	local response_file="$3"
	(
		cd "${project_root}" || exit 1
		MCPBASH_PROJECT_ROOT="${project_root}" mcp-bash <"${request_file}" >"${response_file}"
	)
}

create_project_root() {
	local dest="$1"
	mkdir -p "${dest}/tools" "${dest}/resources" "${dest}/prompts" "${dest}/server.d"
}

# --- Test project setup ---
PROJECT_ROOT="${TEST_TMPDIR}/config_test"
create_project_root "${PROJECT_ROOT}"

# Create config files
echo '{"api_key": "from_file", "timeout": 30}' >"${PROJECT_ROOT}/config.json"
echo '{"api_key": "from_example", "retries": 3, "timeout": 10}' >"${PROJECT_ROOT}/config.example.json"

# --- Create all tools before running any server (registry is cached) ---

# Tool 1: config-tool
mkdir -p "${PROJECT_ROOT}/tools/config-tool"
echo '{"name": "config-tool", "description": "Test mcp_config_load helper"}' \
	>"${PROJECT_ROOT}/tools/config-tool/tool.meta.json"

cat >"${PROJECT_ROOT}/tools/config-tool/tool.sh" <<'TOOL'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"

# Load config with precedence
mcp_config_load \
  --example "${MCPBASH_PROJECT_ROOT}/config.example.json" \
  --file "${MCPBASH_PROJECT_ROOT}/config.json" \
  --defaults '{"debug": false}'

# Get values
api_key=$(mcp_config_get '.api_key')
timeout=$(mcp_config_get '.timeout')
retries=$(mcp_config_get '.retries')
debug=$(mcp_config_get '.debug')

mcp_result_success "$(mcp_json_obj api_key "$api_key" timeout "$timeout" retries "$retries" debug "$debug")"
TOOL
chmod +x "${PROJECT_ROOT}/tools/config-tool/tool.sh"

# Tool 2: config-required
mkdir -p "${PROJECT_ROOT}/tools/config-required"
echo '{"name": "config-required", "description": "Test missing required config"}' \
	>"${PROJECT_ROOT}/tools/config-required/tool.meta.json"

cat >"${PROJECT_ROOT}/tools/config-required/tool.sh" <<'TOOL'
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"

# Load config with non-empty defaults (won't fail even if file missing)
mcp_config_load \
  --file "${MCPBASH_PROJECT_ROOT}/nonexistent-config.json" \
  --defaults '{"other": "value"}'

# Try to get required value (should fail and trigger the error)
secret=$(mcp_config_get '.secret') || mcp_fail_invalid_args "Missing required config: secret"

mcp_result_success '{"ok":true}'
TOOL
chmod +x "${PROJECT_ROOT}/tools/config-required/tool.sh"

# --- Test 1: Tool loads config and uses values ---
printf ' -> Test 1: Tool loads config and uses values\n'

cat >"${TEST_TMPDIR}/req1.jsonl" <<'REQ'
{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"config-tool","arguments":{}}}
REQ

run_server "${PROJECT_ROOT}" "${TEST_TMPDIR}/req1.jsonl" "${TEST_TMPDIR}/resp1.jsonl"

# Check response using helper
assert_ndjson_has "${TEST_TMPDIR}/resp1.jsonl" '.id == 1 and .result.isError == false'
assert_ndjson_has "${TEST_TMPDIR}/resp1.jsonl" '.id == 1 and .result.structuredContent.result.api_key == "from_file"'
assert_ndjson_has "${TEST_TMPDIR}/resp1.jsonl" '.id == 1 and .result.structuredContent.result.timeout == "30"'
assert_ndjson_has "${TEST_TMPDIR}/resp1.jsonl" '.id == 1 and .result.structuredContent.result.retries == "3"'
assert_ndjson_has "${TEST_TMPDIR}/resp1.jsonl" '.id == 1 and .result.structuredContent.result.debug == "false"'

echo "✓ Test 1: Tool loads config and uses values"

# --- Test 2: Tool fails gracefully with missing required config ---
printf ' -> Test 2: Tool fails gracefully with missing required config\n'

cat >"${TEST_TMPDIR}/req2.jsonl" <<'REQ'
{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"config-required","arguments":{}}}
REQ

run_server "${PROJECT_ROOT}" "${TEST_TMPDIR}/req2.jsonl" "${TEST_TMPDIR}/resp2.jsonl"

# Verify it returned an error with the message about missing secret
assert_ndjson_has "${TEST_TMPDIR}/resp2.jsonl" '.id == 2 and .error.code == -32602'
assert_ndjson_has "${TEST_TMPDIR}/resp2.jsonl" '.id == 2 and (.error.message | contains("secret"))'

echo "✓ Test 2: Tool fails gracefully with missing config"

echo ""
echo "All integration tests passed!"
