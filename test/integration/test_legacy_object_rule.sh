#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Before 2026-07-28 structuredContent and outputSchema are objects only; modern clients get any JSON."

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
mkdir -p "${WS}/server.d"
printf '%s\n' '{"name":"object-rule"}' >"${WS}/server.d/server.meta.json"

# add_tool NAME OUTPUT [SCHEMA]: a tool that prints OUTPUT as is.
add_tool() {
	mkdir -p "${WS}/tools/$1"
	if [ -n "${3:-}" ]; then
		printf '{"name":"%s","description":"t","inputSchema":{"type":"object"},"outputSchema":%s}\n' "$1" "$3" >"${WS}/tools/$1/tool.meta.json"
	else
		printf '{"name":"%s","description":"t","inputSchema":{"type":"object"}}\n' "$1" >"${WS}/tools/$1/tool.meta.json"
	fi
	printf '#!/usr/bin/env bash\nprintf %%s %q\n' "$2" >"${WS}/tools/$1/tool.sh"
	chmod +x "${WS}/tools/$1/tool.sh"
}
add_tool arr '[1,2]' '{"type":"array","items":{"type":"number"}}'
add_tool scal '42'
add_tool obj '{"a":1}' '{"type":"object","properties":{"a":{"type":"number"}}}'
add_tool untyped '{"a":1}' '{"properties":{"a":{"type":"number"}}}'
add_tool pass '{"content":[{"type":"text","text":"x"}],"structuredContent":[1],"isError":false}'

call() { printf '{"jsonrpc":"2.0","id":"%s","method":"tools/call","params":{"name":"%s","arguments":{}%s}}\n' "$1" "$1" "${2:-}"; }
res() { jq -c --arg id "$2" 'select(.id == $id) | .result' "$1"; }
schema_of() { jq -c --arg t "$2" --arg id "$3" 'select(.id == $id) | .result.tools[] | select(.name == $t) | .outputSchema // null' "$1"; }

printf ' -> a legacy (2025-11-25) client\n'
REQ="${TEST_TMPDIR}/legacy.ndjson"
{
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
	printf '%s\n' '{"jsonrpc":"2.0","id":"list","method":"tools/list","params":{}}'
	for t in arr scal obj untyped pass; do call "${t}"; done
} >"${REQ}"
OUT="${TEST_TMPDIR}/legacy.out"
test_run_mcp "${WS}" "${REQ}" "${OUT}"
assert_json_lines "${OUT}"
assert_eq "null" "$(schema_of "${OUT}" arr list)" "legacy: a non-object outputSchema isn't listed"
assert_eq '"object"' "$(schema_of "${OUT}" obj list | jq -c '.type')" "legacy: an object outputSchema is listed"
assert_eq "true" "$(schema_of "${OUT}" untyped list | jq -c 'type == "object"')" "legacy: a schema without a type is listed"
for t in arr scal pass; do
	r="$(res "${OUT}" "${t}")"
	assert_eq "[false,false]" "$(printf '%s' "${r}" | jq -c '[.isError, has("structuredContent")]')" "legacy ${t}: text only: ${r}"
done
assert_eq "[1,2]" "$(res "${OUT}" arr | jq -r '.content[0].text')" "legacy arr: the JSON is the text"
assert_eq '{"a":1}' "$(res "${OUT}" obj | jq -c '.structuredContent')" "legacy obj: object structuredContent"

printf ' -> a modern (2026-07-28) client gets any JSON\n'
META=',"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'
MREQ="${TEST_TMPDIR}/modern.ndjson"
{
	printf '{"jsonrpc":"2.0","id":"mlist","method":"tools/list","params":{%s}}\n' "${META#,}"
	for t in arr scal pass; do call "${t}" "${META}"; done
} >"${MREQ}"
OUT="${TEST_TMPDIR}/modern.out"
MCPBASH_MODERN_PROTOCOL=true test_run_mcp "${WS}" "${MREQ}" "${OUT}"
assert_json_lines "${OUT}"
assert_eq '"array"' "$(schema_of "${OUT}" arr mlist | jq -c '.type')" "modern: the array outputSchema is listed"
assert_eq "[1,2]" "$(res "${OUT}" arr | jq -c '.structuredContent')" "modern arr"
assert_eq "42" "$(res "${OUT}" scal | jq -c '.structuredContent')" "modern scal"
assert_eq "[1]" "$(res "${OUT}" pass | jq -c '.structuredContent')" "modern pass"

printf 'Legacy object rule checks passed.\n'
