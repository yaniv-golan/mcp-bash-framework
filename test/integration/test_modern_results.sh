#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Modern (2026-07-28) results: resultType, serverInfo, caching hints and error codes."

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
WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
mkdir -p "${WS}/server.d" "${WS}/tools/hello" "${WS}/resources" "${WS}/prompts"
printf '%s\n' '{"name": "modern-results"}' >"${WS}/server.d/server.meta.json"
printf '%s\n' '{"name":"hello","description":"t","inputSchema":{"type":"object"}}' >"${WS}/tools/hello/tool.meta.json"
printf '#!/usr/bin/env bash\necho hi\n' >"${WS}/tools/hello/tool.sh"
chmod +x "${WS}/tools/hello/tool.sh"
printf 'note\n' >"${WS}/resources/note.txt"
printf '%s\n' '{"name":"note","description":"n","uri":"file://./resources/note.txt","mimeType":"text/plain","provider":"file"}' >"${WS}/resources/note.meta.json"
printf 'Hello\n' >"${WS}/prompts/hello.txt"
printf '%s\n' '{"name":"hello","description":"p","path":"hello.txt","arguments":{"type":"object","properties":{}}}' >"${WS}/prompts/hello.meta.json"

modern() {
	local method="$1" id="$2" params="${3:-}"
	[ -n "${params}" ] || params='{}'
	jq -cn --arg m "${method}" --argjson id "${id}" --argjson p "${params}" \
		'{jsonrpc: "2.0", id: $id, method: $m, params: ($p + {_meta: {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}})}'
}
resp() { jq -c --argjson id "$2" 'select(.id == $id)' "$1"; }

REQ="${TEST_TMPDIR}/req.ndjson"
{
	modern tools/list 1
	modern prompts/list 2
	modern resources/list 3
	modern resources/templates/list 4
	modern resources/read 5 "{\"uri\":\"file://${WS}/resources/note.txt\"}"
	modern tools/call 6 '{"name":"hello","arguments":{}}'
	modern resources/read 7 '{"uri":"file:///no/such/resource.txt"}'
	modern prompts/get 8 '{"name":"hello","arguments":{}}'
} >"${REQ}"
OUT="${TEST_TMPDIR}/out.ndjson"
MCPBASH_MODERN_PROTOCOL=true MCPBASH_TOOL_ALLOWLIST='*' MCPBASH_ROOTS="${WS}" test_run_mcp "${WS}" "${REQ}" "${OUT}"
assert_json_lines "${OUT}"

# Every result: resultType "complete" and serverInfo in _meta.
for id in 1 2 3 4 5 6 8; do
	r="$(resp "${OUT}" "${id}")"
	printf '%s' "${r}" | jq -e '.result.resultType == "complete"' >/dev/null || test_fail "id ${id}: no resultType: ${r}"
	assert_eq "modern-results" "$(printf '%s' "${r}" | jq -r '.result._meta["io.modelcontextprotocol/serverInfo"].name')" "id ${id}: serverInfo"
done
# Caching hints on the lists and on resources/read only.
for id in 1 2 3 4; do
	assert_eq "5000 private" "$(resp "${OUT}" "${id}" | jq -r '"\(.result.ttlMs) \(.result.cacheScope)"')" "id ${id}: list caching hints"
done
assert_eq "0 private" "$(resp "${OUT}" 5 | jq -r '"\(.result.ttlMs) \(.result.cacheScope)"')" "resources/read caching hints"
resp "${OUT}" 6 | jq -e '.result | has("ttlMs") | not' >/dev/null || test_fail "tools/call must not carry caching hints"
# The tool's own _meta is kept next to serverInfo.
assert_eq "0" "$(resp "${OUT}" 6 | jq -r '.result._meta.exitCode')" "tools/call keeps _meta.exitCode"
# Resource not found is -32602 on 2026-07-28 (-32002 is legacy-only).
assert_eq "-32602" "$(resp "${OUT}" 7 | jq -r '.error.code')" "resource not found"

# The list TTL and scope can be set.
REQ2="${TEST_TMPDIR}/req2.ndjson"
modern tools/list 1 >"${REQ2}"
MCPBASH_MODERN_PROTOCOL=true MCPBASH_MODERN_LIST_TTL_MS=60000 MCPBASH_MODERN_CACHE_SCOPE=public MCPBASH_TOOL_ALLOWLIST='*' test_run_mcp "${WS}" "${REQ2}" "${TEST_TMPDIR}/out2.ndjson"
assert_eq "60000 public" "$(resp "${TEST_TMPDIR}/out2.ndjson" 1 | jq -r '"\(.result.ttlMs) \(.result.cacheScope)"')" "configured caching hints"

printf 'Modern result checks passed.\n'
