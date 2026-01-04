#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="SDK CallToolResult helpers (mcp_result_success, mcp_result_error, mcp_json_truncate)."
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
PROJECT_ROOT="${TEST_TMPDIR}/result_helpers"
create_project_root "${PROJECT_ROOT}"

# Create a tool that uses mcp_result_success
mkdir -p "${PROJECT_ROOT}/tools/success-test"
cat <<'METADATA' >"${PROJECT_ROOT}/tools/success-test/tool.meta.json"
{
  "name": "success-test",
  "description": "Test mcp_result_success helper",
  "arguments": {
    "type": "object",
    "properties": {
      "data": { "type": "string", "description": "JSON data to return" }
    },
    "required": ["data"]
  }
}
METADATA

cat <<'TOOL' >"${PROJECT_ROOT}/tools/success-test/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"

data=$(mcp_args_require '.data')
mcp_result_success "$data"
TOOL
chmod +x "${PROJECT_ROOT}/tools/success-test/tool.sh"

# Create a tool that uses mcp_result_error
mkdir -p "${PROJECT_ROOT}/tools/error-test"
cat <<'METADATA' >"${PROJECT_ROOT}/tools/error-test/tool.meta.json"
{
  "name": "error-test",
  "description": "Test mcp_result_error helper",
  "arguments": {
    "type": "object",
    "properties": {
      "error_type": { "type": "string" },
      "message": { "type": "string" }
    },
    "required": ["error_type", "message"]
  }
}
METADATA

cat <<'TOOL' >"${PROJECT_ROOT}/tools/error-test/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"

error_type=$(mcp_args_require '.error_type')
message=$(mcp_args_require '.message')
mcp_result_error "$(jq -n --arg t "$error_type" --arg m "$message" '{type: $t, message: $m}')"
TOOL
chmod +x "${PROJECT_ROOT}/tools/error-test/tool.sh"

# Create a tool that uses mcp_json_truncate
mkdir -p "${PROJECT_ROOT}/tools/truncate-test"
cat <<'METADATA' >"${PROJECT_ROOT}/tools/truncate-test/tool.meta.json"
{
  "name": "truncate-test",
  "description": "Test mcp_json_truncate helper",
  "arguments": {
    "type": "object",
    "properties": {
      "count": { "type": "integer", "description": "Number of items to generate" },
      "max_bytes": { "type": "integer", "description": "Max bytes for truncation" }
    },
    "required": ["count", "max_bytes"]
  }
}
METADATA

cat <<'TOOL' >"${PROJECT_ROOT}/tools/truncate-test/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"

count=$(mcp_args_require '.count')
max_bytes=$(mcp_args_require '.max_bytes')

# Generate array of items
data=$(jq -n --argjson c "$count" '[range($c)] | map({id: ., name: "item-\(.)"})')
truncated=$(mcp_json_truncate "$data" "$max_bytes")

mcp_result_success "$truncated"
TOOL
chmod +x "${PROJECT_ROOT}/tools/truncate-test/tool.sh"

# --- Test: mcp_result_success with simple object ---
printf ' -> mcp_result_success returns structured envelope\n'

cat <<'EOF' >"${TEST_TMPDIR}/success_request.ndjson"
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"success-test","arguments":{"data":"{\"foo\":\"bar\"}"}}}
EOF

run_server "${PROJECT_ROOT}" "${TEST_TMPDIR}/success_request.ndjson" "${TEST_TMPDIR}/success_response.ndjson"

# Check response structure
assert_ndjson_has "${TEST_TMPDIR}/success_response.ndjson" '.id == 2 and .result.structuredContent.success == true'
assert_ndjson_has "${TEST_TMPDIR}/success_response.ndjson" '.id == 2 and .result.structuredContent.result.foo == "bar"'
assert_ndjson_has "${TEST_TMPDIR}/success_response.ndjson" '.id == 2 and .result.isError == false'

# --- Test: mcp_result_error returns error envelope ---
printf ' -> mcp_result_error returns error envelope with isError=true\n'

cat <<'EOF' >"${TEST_TMPDIR}/error_request.ndjson"
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"error-test","arguments":{"error_type":"not_found","message":"User not found"}}}
EOF

run_server "${PROJECT_ROOT}" "${TEST_TMPDIR}/error_request.ndjson" "${TEST_TMPDIR}/error_response.ndjson"

assert_ndjson_has "${TEST_TMPDIR}/error_response.ndjson" '.id == 2 and .result.isError == true'
assert_ndjson_has "${TEST_TMPDIR}/error_response.ndjson" '.id == 2 and .result.structuredContent.success == false'
assert_ndjson_has "${TEST_TMPDIR}/error_response.ndjson" '.id == 2 and .result.structuredContent.error.type == "not_found"'
assert_ndjson_has "${TEST_TMPDIR}/error_response.ndjson" '.id == 2 and .result.content[0].text == "User not found"'

# --- Test: mcp_json_truncate truncates large arrays ---
printf ' -> mcp_json_truncate truncates large arrays\n'

cat <<'EOF' >"${TEST_TMPDIR}/truncate_request.ndjson"
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"truncate-test","arguments":{"count":100,"max_bytes":200}}}
EOF

run_server "${PROJECT_ROOT}" "${TEST_TMPDIR}/truncate_request.ndjson" "${TEST_TMPDIR}/truncate_response.ndjson"

assert_ndjson_has "${TEST_TMPDIR}/truncate_response.ndjson" '.id == 2 and .result.structuredContent.result.truncated == true'
assert_ndjson_has "${TEST_TMPDIR}/truncate_response.ndjson" '.id == 2 and .result.structuredContent.result.kept < .result.structuredContent.result.total'

# --- Test: mcp_result_success handles JSON false value ---
printf ' -> mcp_result_success handles JSON false value\n'

cat <<'EOF' >"${TEST_TMPDIR}/false_request.ndjson"
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"success-test","arguments":{"data":"false"}}}
EOF

run_server "${PROJECT_ROOT}" "${TEST_TMPDIR}/false_request.ndjson" "${TEST_TMPDIR}/false_response.ndjson"

assert_ndjson_has "${TEST_TMPDIR}/false_response.ndjson" '.id == 2 and .result.structuredContent.success == true'
assert_ndjson_has "${TEST_TMPDIR}/false_response.ndjson" '.id == 2 and .result.structuredContent.result == false'
assert_ndjson_has "${TEST_TMPDIR}/false_response.ndjson" '.id == 2 and .result.isError == false'

# --- Test: mcp_result_success handles null value ---
printf ' -> mcp_result_success handles JSON null value\n'

cat <<'EOF' >"${TEST_TMPDIR}/null_request.ndjson"
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"success-test","arguments":{"data":"null"}}}
EOF

run_server "${PROJECT_ROOT}" "${TEST_TMPDIR}/null_request.ndjson" "${TEST_TMPDIR}/null_response.ndjson"

assert_ndjson_has "${TEST_TMPDIR}/null_response.ndjson" '.id == 2 and .result.structuredContent.success == true'
assert_ndjson_has "${TEST_TMPDIR}/null_response.ndjson" '.id == 2 and .result.structuredContent.result == null'

printf 'Integration test for result helpers passed.\n'
