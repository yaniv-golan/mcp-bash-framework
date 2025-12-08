#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Verify _meta from tools/call is passed to tools via MCP_TOOL_META_JSON."
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
	local workdir="$1"
	local request_file="$2"
	local response_file="$3"
	(
		cd "${workdir}" || exit 1
		MCPBASH_PROJECT_ROOT="${workdir}" ./bin/mcp-bash <"${request_file}" >"${response_file}"
	)
}

# --- Test _meta passing ---
META_ROOT="${TEST_TMPDIR}/meta"
test_stage_workspace "${META_ROOT}"
rm -f "${META_ROOT}/server.d/register.sh"
mkdir -p "${META_ROOT}/tools/echo-meta"

# Create a tool that echoes back the _meta it receives
cat <<'METADATA' >"${META_ROOT}/tools/echo-meta/tool.meta.json"
{
  "name": "echo-meta",
  "description": "Echoes back the _meta received from the request",
  "inputSchema": {
    "type": "object",
    "properties": {}
  }
}
METADATA

cat <<'SH' >"${META_ROOT}/tools/echo-meta/tool.sh"
#!/usr/bin/env bash
set -euo pipefail

if [ -z "${MCP_SDK:-}" ]; then
	printf 'MCP_SDK not set\n' >&2
	exit 1
fi
# shellcheck disable=SC1091
source "${MCP_SDK}/tool-sdk.sh"

# Get the raw _meta JSON and emit it as the tool result
meta_raw="$(mcp_meta_raw)"
mcp_emit_text "meta=${meta_raw}"
SH
chmod +x "${META_ROOT}/tools/echo-meta/tool.sh"

# Test 1: Call with _meta containing custom key-value pairs
cat <<'JSON' >"${META_ROOT}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call-with-meta","method":"tools/call","params":{"name":"echo-meta","arguments":{},"_meta":{"appName":"TestApp","userId":"user123","config":{"maxResults":10}}}}
{"jsonrpc":"2.0","id":"call-empty-meta","method":"tools/call","params":{"name":"echo-meta","arguments":{}}}
{"jsonrpc":"2.0","id":"call-progress-token","method":"tools/call","params":{"name":"echo-meta","arguments":{},"_meta":{"progressToken":"tok-123"}}}
JSON

run_server "${META_ROOT}" "${META_ROOT}/requests.ndjson" "${META_ROOT}/responses.ndjson"

# Verify call with custom _meta
call_meta_resp="$(grep '"id":"call-with-meta"' "${META_ROOT}/responses.ndjson" | head -n1)"
if [ -z "${call_meta_resp}" ]; then
	test_fail "missing response for call-with-meta"
fi
meta_text="$(echo "${call_meta_resp}" | jq -r '.result.content[] | select(.type=="text") | .text' | head -n1)"
if [[ "${meta_text}" != *'"appName":"TestApp"'* ]]; then
	test_fail "expected _meta to contain appName, got: ${meta_text}"
fi
if [[ "${meta_text}" != *'"userId":"user123"'* ]]; then
	test_fail "expected _meta to contain userId, got: ${meta_text}"
fi
if [[ "${meta_text}" != *'"maxResults":10'* ]]; then
	test_fail "expected _meta to contain nested config.maxResults, got: ${meta_text}"
fi
printf ' -> _meta with custom keys passed correctly\n'

# Verify call with empty _meta (should get empty object)
call_empty_resp="$(grep '"id":"call-empty-meta"' "${META_ROOT}/responses.ndjson" | head -n1)"
if [ -z "${call_empty_resp}" ]; then
	test_fail "missing response for call-empty-meta"
fi
empty_text="$(echo "${call_empty_resp}" | jq -r '.result.content[] | select(.type=="text") | .text' | head -n1)"
if [[ "${empty_text}" != "meta={}" ]]; then
	test_fail "expected empty _meta to be {}, got: ${empty_text}"
fi
printf ' -> empty _meta passed as {}\n'

# Verify call with progressToken in _meta
call_progress_resp="$(grep '"id":"call-progress-token"' "${META_ROOT}/responses.ndjson" | head -n1)"
if [ -z "${call_progress_resp}" ]; then
	test_fail "missing response for call-progress-token"
fi
progress_text="$(echo "${call_progress_resp}" | jq -r '.result.content[] | select(.type=="text") | .text' | head -n1)"
if [[ "${progress_text}" != *'"progressToken":"tok-123"'* ]]; then
	test_fail "expected _meta to contain progressToken, got: ${progress_text}"
fi
printf ' -> _meta with progressToken passed correctly\n'

# Test 2: Verify mcp_meta_get works with jq filter
cat <<'SH' >"${META_ROOT}/tools/echo-meta/tool.sh"
#!/usr/bin/env bash
set -euo pipefail

if [ -z "${MCP_SDK:-}" ]; then
	printf 'MCP_SDK not set\n' >&2
	exit 1
fi
# shellcheck disable=SC1091
source "${MCP_SDK}/tool-sdk.sh"

# Use mcp_meta_get to extract specific values
app_name="$(mcp_meta_get '.appName // "default"')"
limit="$(mcp_meta_get '.limit // 5')"
mcp_emit_text "app=${app_name},limit=${limit}"
SH
chmod +x "${META_ROOT}/tools/echo-meta/tool.sh"

cat <<'JSON' >"${META_ROOT}/requests2.ndjson"
{"jsonrpc":"2.0","id":"init2","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call-get-meta","method":"tools/call","params":{"name":"echo-meta","arguments":{},"_meta":{"appName":"MyApp","limit":25}}}
JSON

run_server "${META_ROOT}" "${META_ROOT}/requests2.ndjson" "${META_ROOT}/responses2.ndjson"

call_get_resp="$(grep '"id":"call-get-meta"' "${META_ROOT}/responses2.ndjson" | head -n1)"
if [ -z "${call_get_resp}" ]; then
	test_fail "missing response for call-get-meta"
fi
get_text="$(echo "${call_get_resp}" | jq -r '.result.content[] | select(.type=="text") | .text' | head -n1)"
if [[ "${get_text}" != "app=MyApp,limit=25" ]]; then
	test_fail "expected mcp_meta_get to extract values, got: ${get_text}"
fi
printf ' -> mcp_meta_get extracts values correctly\n'

printf 'PASS: %s\n' "${TEST_DESC}"
