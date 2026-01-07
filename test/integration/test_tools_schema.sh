#!/usr/bin/env bash
# Integration: tool outputSchema validation and list_changed notification TTL.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Tool outputSchema validation and TTL behavior."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/tools-schema"
test_stage_workspace "${WORKSPACE}"

mkdir -p "${WORKSPACE}/tools/schema"
cat <<'META' >"${WORKSPACE}/tools/schema/tool.meta.json"
{"name":"schema.tool","description":"structured","arguments":{"type":"object","properties":{}},"outputSchema":{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}}
META
cat <<'SH' >"${WORKSPACE}/tools/schema/tool.sh"
#!/usr/bin/env bash
echo '{"msg":"bad"}'
SH
chmod +x "${WORKSPACE}/tools/schema/tool.sh"

# Build initial registry and call tool synchronously
cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"schema.tool","arguments":{}}}
JSON

(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" MCPBASH_DEBUG_ERRORS=true ./bin/mcp-bash <"${WORKSPACE}/requests.ndjson" >"${WORKSPACE}/responses.ndjson"
) || true

call_error="$(jq -r 'select(.id=="call") | .error.code // empty' "${WORKSPACE}/responses.ndjson")"
if [ "${call_error}" = "" ]; then
	test_fail "schema mismatch did not produce error"
fi
call_error_tool="$(jq -r 'select(.id=="call") | .error.data.tool // empty' "${WORKSPACE}/responses.ndjson")"
test_assert_eq "schema.tool" "${call_error_tool}" "expected debug error payload to include tool name"
call_error_exit="$(jq -r 'select(.id=="call") | .error.data.exitCode // empty' "${WORKSPACE}/responses.ndjson")"
test_assert_eq "0" "${call_error_exit}" "expected debug error payload to include exit code"
call_error_trace="$(jq -r 'select(.id=="call") | .error.data.traceAvailable | tostring' "${WORKSPACE}/responses.ndjson")"
test_assert_eq "false" "${call_error_trace}" "expected debug error payload to include trace availability"

# Modify tool metadata and script to force list_changed
# Invalidate registry cache so the change is detected (TTL-based detection is timing-dependent)
test_invalidate_registry_cache "${WORKSPACE}"
cat <<'META' >"${WORKSPACE}/tools/schema/tool.meta.json"
{"name":"schema.tool","description":"structured (updated)","arguments":{"type":"object","properties":{}},"outputSchema":{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}}
META
cat <<'SH' >"${WORKSPACE}/tools/schema/tool.sh"
#!/usr/bin/env bash
echo '{"message":"ok"}'
SH
chmod +x "${WORKSPACE}/tools/schema/tool.sh"

cat <<'JSON' >"${WORKSPACE}/followup.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list","method":"tools/list"}
{"jsonrpc":"2.0","id":"ping","method":"ping"}
JSON

(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" MCP_TOOLS_TTL=1 ./bin/mcp-bash <"${WORKSPACE}/followup.ndjson" >"${WORKSPACE}/followup.out"
) || true

list_changed="$(grep -c 'notifications/tools/list_changed' "${WORKSPACE}/followup.out" || true)"
if [ "${list_changed}" -lt 1 ]; then
	test_fail "expected tools/list_changed notification after modification"
fi

printf 'Tool schema tests passed.\n'
