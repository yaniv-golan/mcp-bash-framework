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
cat >"${TEST_TMPDIR}/envelope.meta.json" <<'JSON'
{"name": "env", "description": "t", "inputSchema": {"type": "object"},
 "outputSchema": {"type": "object", "required": ["success", "result"], "properties": {"success": {"type": "boolean"},
  "result": {"type": "object", "properties": {"n": {"type": "string"}}}}}}
JSON
cp "${TEST_TMPDIR}/envelope.meta.json" "${WS}/tools/env/tool.meta.json"

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
grep -q 'tools cache' "${TEST_TMPDIR}/migrate.out" || test_fail "migrate --write did not say it cleared the cache: $(cat "${TEST_TMPDIR}/migrate.out")"
[ ! -e "${WS}/.registry/tools.json" ] || test_fail "tools.json is still cached after migrate --write"

session "${TEST_TMPDIR}/after.ndjson"
r="$(result "${TEST_TMPDIR}/after.ndjson")"
assert_eq '[false,"1"]' "$(printf '%s' "${r}" | jq -c '[.isError, .structuredContent.n]')" "right after migrate --write: ${r}"

# A project in git that tracks some registry files: they stay as they are.
# migrate only invalidates the tools cache (it rewrites tool metadata); a
# tracked tools.json is expired rather than deleted.
WS2="${TEST_TMPDIR}/tracked"
cp -R "${WS}" "${WS2}"
rm -rf "${WS2}/.registry"
printf '%s\n' '#!/usr/bin/env bash' 'source "${MCP_SDK}/tool-sdk.sh"' 'mcp_result_success "$(mcp_json_obj n 1)"' >"${WS2}/tools/env/tool.sh"
cp "${TEST_TMPDIR}/envelope.meta.json" "${WS2}/tools/env/tool.meta.json"
WS="${WS2}" session "${TEST_TMPDIR}/tracked-before.ndjson"
printf '%s\n' '{"tracked":true}' >"${WS2}/.registry/prompts.json"
printf '%s\n' '{"tracked":true}' >"${WS2}/.registry/resources.json"
# A findings file someone committed anyway: emptied, not just re-dated,
# so the next start sends no stale note.
mkdir -p "${WS2}/.registry/scan"
printf '%s\n' tools/env/tool.sh >"${WS2}/.registry/scan/removed-api.findings"
(
	cd "${WS2}" && git init -q && git add -A && git add -f .registry/scan/removed-api.findings \
		&& git -c user.email=t@t -c user.name=t commit -q -m init
) || test_fail "git setup failed"
(cd "${FW}" && ./bin/mcp-bash migrate --project-root "${WS2}" --write >"${TEST_TMPDIR}/migrate2.out" 2>&1) || true
grep -q 'mcp_result_json' "${WS2}/tools/env/tool.sh" || test_fail "tracked project: not migrated"
deleted="$(git -C "${WS2}" status --porcelain | awk '$1 == "D"')"
[ -z "${deleted}" ] || test_fail "migrate --write deleted tracked files: ${deleted}"
test_assert_eq "$(cat "${WS2}/.registry/prompts.json")" '{"tracked":true}'
test_assert_eq "$(wc -c <"${WS2}/.registry/scan/removed-api.findings" | tr -d ' ')" "0"
WS="${WS2}" session "${TEST_TMPDIR}/tracked-after.ndjson"
r="$(result "${TEST_TMPDIR}/tracked-after.ndjson")"
assert_eq '[false,"1"]' "$(printf '%s' "${r}" | jq -c '[.isError, .structuredContent.n]')" "tracked tools.json, right after migrate --write: ${r}"

printf 'Migrate registry cache checks passed.\n'
