#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="server/discover (2026-07-28): static answer, no registry scan, before or after a legacy session."

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
mkdir -p "${WS}/server.d" "${WS}/tools/hello"
printf '%s\n' '{"name": "discover-test", "version": "1.2.3"}' >"${WS}/server.d/server.meta.json"
printf 'Use the hello tool.\n' >"${WS}/server.d/server.instructions.md"
printf '%s\n' '{"name":"hello","description":"t","inputSchema":{"type":"object"}}' >"${WS}/tools/hello/tool.meta.json"
printf '#!/usr/bin/env bash\necho hi\n' >"${WS}/tools/hello/tool.sh"
chmod +x "${WS}/tools/hello/tool.sh"
rm -rf "${WS}/.registry"

discover() {
	local id="$1" caps="${2:-}"
	[ -n "${caps}" ] || caps='{}'
	jq -cn --argjson id "${id}" --argjson c "${caps}" \
		'{jsonrpc: "2.0", id: $id, method: "server/discover", params: {_meta: {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": $c}}}'
}
resp() { jq -c --argjson id "$2" 'select(.id == $id)' "$1"; }

# --- A probe-only process: answered, fast, without scanning the project ------
REQ="${TEST_TMPDIR}/probe.ndjson"
{
	discover 1
	discover 2 '{"extensions":{"io.modelcontextprotocol/ui":{}}}'
	printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"server/discover","params":{}}'
} >"${REQ}"
start="${SECONDS}"
MCPBASH_MODERN_PROTOCOL=true test_run_mcp "${WS}" "${REQ}" "${TEST_TMPDIR}/probe.out"
elapsed=$((SECONDS - start))
OUT="${TEST_TMPDIR}/probe.out"
assert_json_lines "${OUT}"
r="$(resp "${OUT}" 1 | jq -c '.result')"
assert_eq '["2026-07-28","2025-11-25","2025-06-18","2025-03-26","2024-11-05"]' "$(printf '%s' "${r}" | jq -c '.supportedVersions')" "supportedVersions"
assert_eq "complete" "$(printf '%s' "${r}" | jq -r '.resultType')" "resultType"
assert_eq "5000" "$(printf '%s' "${r}" | jq -r '.ttlMs')" "ttlMs"
assert_eq "private" "$(printf '%s' "${r}" | jq -r '.cacheScope')" "cacheScope"
assert_eq "discover-test" "$(printf '%s' "${r}" | jq -r '._meta["io.modelcontextprotocol/serverInfo"].name')" "serverInfo in _meta"
assert_eq "Use the hello tool." "$(printf '%s' "${r}" | jq -r '.instructions' | tr -d '\n')" "instructions"
# No listChanged or subscribe: on 2026-07-28 they mean subscriptions/listen.
if printf '%s' "${r}" | jq -e '[.capabilities[] | objects | (.listChanged, .subscribe)] | any' >/dev/null; then
	test_fail "discover advertises listChanged/subscribe: ${r}"
fi
printf '%s' "${r}" | jq -e '.capabilities | has("extensions") | not' >/dev/null || test_fail "UI extension without the client asking: ${r}"
resp "${OUT}" 2 | jq -e '.result.capabilities.extensions["io.modelcontextprotocol/ui"]' >/dev/null || test_fail "UI extension missing for a UI client"
assert_eq "-32602" "$(resp "${OUT}" 3 | jq -r '.error.code')" "server/discover without the modern _meta"
[ ! -e "${WS}/.registry/tools.json" ] || test_fail "server/discover scanned the tools registry"
[ "${elapsed}" -lt 5 ] || test_fail "a probe-only session took ${elapsed}s"

# --- After a legacy session in the same process -------------------------------
REQ="${TEST_TMPDIR}/mixed.ndjson"
{
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
	discover 1
} >"${REQ}"
MCPBASH_MODERN_PROTOCOL=true test_run_mcp "${WS}" "${REQ}" "${TEST_TMPDIR}/mixed.out"
assert_eq "complete" "$(resp "${TEST_TMPDIR}/mixed.out" 1 | jq -r '.result.resultType')" "discover after a legacy initialize"

printf 'server/discover checks passed.\n'
