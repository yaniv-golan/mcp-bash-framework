#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="A tool calling an SDK helper removed in 2.0 gets migration_required; migrate --write fixes it."

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
# The framework is staged in FW; the project lives apart from it, as a real
# one does (migrate scans the whole project).
FW="${TEST_TMPDIR}/fw"
test_stage_workspace "${FW}"
WS="${TEST_TMPDIR}/project"
mkdir -p "${WS}/server.d" "${WS}/lib"
printf '%s\n' '{"name": "removed-api"}' >"${WS}/server.d/server.meta.json"

add_tool() {
	local name="$1" body="$2"
	mkdir -p "${WS}/tools/${name}"
	printf '{"name":"%s","description":"t","inputSchema":{"type":"object"}}\n' "${name}" >"${WS}/tools/${name}/tool.meta.json"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		# shellcheck disable=SC2016  # Literal for the generated tool script
		printf 'source "${MCP_SDK}/tool-sdk.sh"\n'
		printf '%s\n' "${body}"
	} >"${WS}/tools/${name}/tool.sh"
	chmod +x "${WS}/tools/${name}/tool.sh"
}
# An unmigrated tool: mcp_error, then exit (migrate rewrites this form).
add_tool unmigrated 'mcp_error not_found "nothing here" --hint "list first"
exit 0'
# mcp_result_success with an envelope outputSchema: migrate rewrites both.
add_tool unmigratedresult 'mcp_result_success "$(mcp_json_obj n 1)"'
cat >"${WS}/tools/unmigratedresult/tool.meta.json" <<'JSON'
{"name": "unmigratedresult", "description": "t", "inputSchema": {"type": "object"},
 "outputSchema": {"type": "object", "required": ["success", "result"], "properties": {"success": {"type": "boolean"},
  "result": {"type": "object", "properties": {"n": {"type": "string"}}}}}}
JSON
# A removed helper in a shared script outside the tool's directory: the
# per-call check can't see it; the "command not found" gets a hint.
printf '%s\n' 'reply_error() {' '	mcp_result_error "{\"type\":\"x\",\"message\":\"m\"}"' '}' >"${WS}/lib/common.sh"
# shellcheck disable=SC2016
add_tool shared 'source "${MCPBASH_PROJECT_ROOT}/lib/common.sh"
reply_error'
# A helper script in the tool's own directory: only the entry script is
# checked, so this one runs and gets the hint too.
# shellcheck disable=SC2016
add_tool withlib 'source "$(dirname "$0")/helpers.lib"
helper'
printf '%s\n' 'helper() {' '	mcp_emit_text "old"' '}' >"${WS}/tools/withlib/helpers.lib"
# Two tools in one directory: the clean one isn't blocked by its neighbour.
mkdir -p "${WS}/tools/grp"
printf '%s\n' '#!/usr/bin/env bash' 'source "${MCP_SDK}/tool-sdk.sh"' 'mcp_result_text "ok"' >"${WS}/tools/grp/flat_ok.sh"
printf '%s\n' '#!/usr/bin/env bash' 'source "${MCP_SDK}/tool-sdk.sh"' 'mcp_error not_found x' 'exit 0' >"${WS}/tools/grp/flat_bad.sh"
chmod +x "${WS}/tools/grp/flat_ok.sh" "${WS}/tools/grp/flat_bad.sh"
# A comment that names a removed helper is not a use.
add_tool commented '# 1.x used mcp_error here
mcp_result_text "fine"'

call() { printf '{"jsonrpc":"2.0","id":"%s","method":"tools/call","params":{"name":"%s","arguments":{}}}\n' "$1" "$1"; }
session() {
	local out="$1" req="${TEST_TMPDIR}/req.ndjson"
	{
		printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'
		printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
		call unmigrated
		call unmigratedresult
		call shared
		call commented
		call withlib
		call flat_ok
		call flat_bad
	} >"${req}"
	(cd "${FW}" && MCPBASH_PROJECT_ROOT="${WS}" MCPBASH_TOOL_ALLOWLIST='*' ./bin/mcp-bash <"${req}" >"${out}" 2>"${out}.stderr")
	assert_json_lines "${out}"
}
resp() { jq -c --arg id "$2" 'select(.id == $id) | .result' "$1"; }

OUT="${TEST_TMPDIR}/before.ndjson"
session "${OUT}"
r="$(resp "${OUT}" unmigrated)"
assert_eq '[true,"migration_required","mcp_error"]' "$(printf '%s' "${r}" | jq -c '[.isError, ._meta["mcpbash/error"].type, ._meta["mcpbash/error"].data.removed]')" "unmigrated tool: ${r}"
case "$(printf '%s' "${r}" | jq -r '.content[0].text')" in
*"mcp-bash migrate"*) ;;
*) test_fail "unmigrated tool: no migrate hint: ${r}" ;;
esac
assert_eq "mcp_result_success" "$(resp "${OUT}" unmigratedresult | jq -r '._meta["mcpbash/error"].data.removed')" "unmigrated mcp_result_success"
r="$(resp "${OUT}" shared)"
assert_eq "tool_failed" "$(printf '%s' "${r}" | jq -r '._meta["mcpbash/error"].type')" "shared script: ${r}"
case "$(printf '%s' "${r}" | jq -r '._meta["mcpbash/error"].hint // empty')" in
*'`mcp_result_error` was removed in mcp-bash 2.0'*) ;;
*) test_fail "shared script: no removed-helper hint: ${r}" ;;
esac
assert_eq "fine" "$(resp "${OUT}" commented | jq -r '.content[0].text')" "a comment naming a removed helper"
r="$(resp "${OUT}" withlib)"
assert_eq "tool_failed" "$(printf '%s' "${r}" | jq -r '._meta["mcpbash/error"].type')" "helper in the tool dir: ${r}"
case "$(printf '%s' "${r}" | jq -r '._meta["mcpbash/error"].hint // empty')" in
*'`mcp_emit_text` was removed in mcp-bash 2.0'*) ;;
*) test_fail "helper in the tool dir: no removed-helper hint: ${r}" ;;
esac
assert_eq "ok" "$(resp "${OUT}" flat_ok | jq -r '.content[0].text')" "a clean tool next to an unmigrated one"
assert_eq "migration_required" "$(resp "${OUT}" flat_bad | jq -r '._meta["mcpbash/error"].type')" "the unmigrated neighbour"

# migrate --write rewrites the unmigrated tool; it then runs.
(cd "${FW}" && ./bin/mcp-bash migrate --project-root "${WS}" --write >"${TEST_TMPDIR}/migrate.out" 2>&1) || true
grep -q 'mcp_fail --type not_found' "${WS}/tools/unmigrated/tool.sh" || test_fail "migrate --write did not rewrite the tool: $(cat "${WS}/tools/unmigrated/tool.sh")"
OUT="${TEST_TMPDIR}/after.ndjson"
session "${OUT}"
r="$(resp "${OUT}" unmigrated)"
assert_eq '[true,"not_found","nothing here"]' "$(printf '%s' "${r}" | jq -c '[.isError, ._meta["mcpbash/error"].type, ._meta["mcpbash/error"].message]')" "migrated tool: ${r}"
r="$(resp "${OUT}" unmigratedresult)"
assert_eq '[false,"1"]' "$(printf '%s' "${r}" | jq -c '[.isError, .structuredContent.n]')" "migrated mcp_result_success tool: ${r}"

printf 'Removed API checks passed.\n'
