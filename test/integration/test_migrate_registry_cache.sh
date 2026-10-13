#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="migrate --write clears the registry cache, so a restart right after it sees the rewritten metadata."

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
FW="${TEST_TMPDIR}/fw"
test_stage_workspace "${FW}"
WS="${TEST_TMPDIR}/project"
mkdir -p "${WS}/server.d" "${WS}/tools/env"
printf '%s\n' '{"name": "migrate-cache"}' >"${WS}/server.d/server.meta.json"
# mcp_result_success with an envelope outputSchema: migrate rewrites both.
{
	printf '#!/usr/bin/env bash\nset -euo pipefail\n'
	# shellcheck disable=SC2016  # Literal for the generated tool script
	printf 'source "${MCP_SDK}/tool-sdk.sh"\n'
	# shellcheck disable=SC2016
	printf 'mcp_result_success "$(mcp_json_obj n 1)"\n'
} >"${WS}/tools/env/tool.sh"
chmod +x "${WS}/tools/env/tool.sh"
cat >"${WS}/tools/env/tool.meta.json" <<'JSON'
{"name": "env", "description": "t", "inputSchema": {"type": "object"},
 "outputSchema": {"type": "object", "required": ["success", "result"], "properties": {"success": {"type": "boolean"},
  "result": {"type": "object", "properties": {"n": {"type": "string"}}}}}}
JSON

REQ="${TEST_TMPDIR}/req.ndjson"
{
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
	printf '%s\n' '{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"env","arguments":{}}}'
} >"${REQ}"
# A long cache lifetime stands for "restarted within the TTL", whatever the
# machine's speed.
session() {
	(cd "${FW}" && MCP_TOOLS_TTL=600 MCPBASH_PROJECT_ROOT="${WS}" MCPBASH_TOOL_ALLOWLIST='*' ./bin/mcp-bash <"${REQ}" >"$1" 2>"$1.stderr")
	assert_json_lines "$1"
}
result() { jq -c 'select(.id == "call") | .result' "$1"; }

session "${TEST_TMPDIR}/before.ndjson"
assert_eq "migration_required" "$(result "${TEST_TMPDIR}/before.ndjson" | jq -r '._meta["mcpbash/error"].type')" "before migrate"
[ -f "${WS}/.registry/tools.json" ] || test_fail "the first session wrote no tools cache"

(cd "${FW}" && ./bin/mcp-bash migrate --project-root "${WS}" --write >"${TEST_TMPDIR}/migrate.out" 2>&1) || true
grep -q 'registry cache' "${TEST_TMPDIR}/migrate.out" || test_fail "migrate --write did not say it cleared the cache: $(cat "${TEST_TMPDIR}/migrate.out")"
[ ! -e "${WS}/.registry/tools.json" ] || test_fail "tools.json is still cached after migrate --write"

session "${TEST_TMPDIR}/after.ndjson"
r="$(result "${TEST_TMPDIR}/after.ndjson")"
assert_eq '[false,"1"]' "$(printf '%s' "${r}" | jq -c '[.isError, .structuredContent.n]')" "right after migrate --write: ${r}"

printf 'Migrate registry cache checks passed.\n'
