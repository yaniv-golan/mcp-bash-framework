#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Modern (2026-07-28) requests: off by default, stateless when on, isolated from a legacy session."

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
mkdir -p "${WS}/server.d" "${WS}/roots-from-env"
printf '%s\n' '{"name": "modern-core"}' >"${WS}/server.d/server.meta.json"

add_tool() {
	local name="$1" body="$2"
	mkdir -p "${WS}/tools/${name}"
	printf '{"name":"%s","description":"t","inputSchema":{"type":"object"}}\n' "${name}" >"${WS}/tools/${name}/tool.meta.json"
	{
		printf '#!/usr/bin/env bash\nset -uo pipefail\n'
		# shellcheck disable=SC2016  # Literal for the generated tool script
		printf 'source "${MCP_SDK}/tool-sdk.sh"\nsource "${MCP_SDK}/ui-sdk.sh"\n'
		printf '%s\n' "${body}"
	} >"${WS}/tools/${name}/tool.sh"
	chmod +x "${WS}/tools/${name}/tool.sh"
}
add_tool uicheck 'if mcp_client_supports_ui; then echo ui-yes; else echo ui-no; fi'
add_tool elicit 'if mcp_elicit_confirm "Proceed?" >/dev/null; then echo answered; else echo no-elicit; fi'
# shellcheck disable=SC2016
add_tool roots 'printf "roots=%s" "${MCP_ROOTS_PATHS:-}"'
add_tool slow 'sleep 30; echo done'

# modern METHOD ID [PARAMS_JSON] [CLIENT_CAPS_JSON] [VERSION]: one modern request line.
modern() {
	local method="$1" id="$2" params="${3:-}" caps="${4:-}" version="${5:-2026-07-28}"
	[ -n "${params}" ] || params='{}'
	[ -n "${caps}" ] || caps='{}'
	jq -cn --arg m "${method}" --argjson id "${id}" --argjson p "${params}" --argjson c "${caps}" --arg v "${version}" \
		'{jsonrpc: "2.0", id: $id, method: $m, params: ($p + {_meta: {"io.modelcontextprotocol/protocolVersion": $v, "io.modelcontextprotocol/clientCapabilities": $c}})}'
}
call_params() { printf '{"name":"%s","arguments":{}}' "$1"; }

run() {
	local out="$1" req="$2"
	shift 2
	(
		local kv
		for kv in "$@"; do
			export "${kv?}"
		done
		MCPBASH_TOOL_ALLOWLIST='*' test_run_mcp "${WS}" "${req}" "${out}"
	)
	assert_json_lines "${out}"
}
resp() { jq -c --argjson id "$2" 'select(.id == $id)' "$1"; }
text_of() { resp "$1" "$2" | jq -r '.result.content[0].text // empty'; }

# --- Switch off (the default): nothing changes ---------------------------------
REQ="${TEST_TMPDIR}/off.ndjson"
{
	modern tools/list 1
	modern server/discover 2
} >"${REQ}"
run "${TEST_TMPDIR}/off.out" "${REQ}"
assert_eq "-32000" "$(resp "${TEST_TMPDIR}/off.out" 1 | jq -r '.error.code')" "off: modern request before initialize is gated"
assert_eq "-32601" "$(resp "${TEST_TMPDIR}/off.out" 2 | jq -r '.error.code')" "off: server/discover is unknown"
assert_eq "Method not found" "$(resp "${TEST_TMPDIR}/off.out" 2 | jq -r '.error.message')" "off: exact message clients key on"

# --- Switch on, modern requests only ------------------------------------------
REQ="${TEST_TMPDIR}/on.ndjson"
{
	modern tools/list 1
	modern tools/list 2 '{}' '{}' 2025-11-25
	jq -cn '{jsonrpc: "2.0", id: 3, method: "tools/list", params: {_meta: {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}}}'
	modern ping 4
	modern logging/setLevel 5 '{"level":"debug"}'
	modern resources/subscribe 6 '{"uri":"file:///x"}'
	modern tools/call 7 "$(call_params roots)" '{"roots":{"listChanged":true}}'
	modern tools/call 8 "$(call_params elicit)" '{"elicitation":{}}'
	modern tools/call 9 "$(call_params uicheck)" '{"extensions":{"io.modelcontextprotocol/ui":{}}}'
	jq -cn '{jsonrpc: "2.0", id: 10, method: "tools/list", params: {_meta: {"io.modelcontextprotocol/protocolVersion": 5, "io.modelcontextprotocol/clientCapabilities": {}}}}'
	jq -cn '{jsonrpc: "2.0", id: 11, method: "tools/list", params: {_meta: {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": "x"}}}'
	jq -cn '{jsonrpc: "2.0", id: 12, method: "tools/list", params: {_meta: {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": null}}}'
	jq -cn '{jsonrpc: "2.0", id: 13, method: "tools/list", params: {_meta: {"io.modelcontextprotocol/protocolVersion": "", "io.modelcontextprotocol/clientCapabilities": {}}}}'
} >"${REQ}"
run "${TEST_TMPDIR}/on.out" "${REQ}" MCPBASH_MODERN_PROTOCOL=true MCPBASH_ROOTS="${WS}/roots-from-env"
OUT="${TEST_TMPDIR}/on.out"
resp "${OUT}" 1 | jq -e '.result.tools | length > 0' >/dev/null || test_fail "on: modern tools/list without initialize: $(resp "${OUT}" 1)"
r="$(resp "${OUT}" 2)"
assert_eq "-32022" "$(printf '%s' "${r}" | jq -r '.error.code')" "on: a legacy version in modern _meta"
assert_eq '["2026-07-28","2025-11-25","2025-06-18","2025-03-26","2024-11-05"]' "$(printf '%s' "${r}" | jq -c '.error.data.supported')" "on: -32022 lists every version"
assert_eq '"2025-11-25"' "$(printf '%s' "${r}" | jq -c '.error.data.requested')" "on: -32022 echoes the requested version"
assert_eq "-32602" "$(resp "${OUT}" 3 | jq -r '.error.code')" "on: missing clientCapabilities"
for id in 10 11 12; do
	assert_eq "-32602" "$(resp "${OUT}" "${id}" | jq -r '.error.code')" "on: a non-string version or non-object capabilities (id ${id}): $(resp "${OUT}" "${id}")"
done
# An empty string is a string: an unsupported version, not invalid params.
assert_eq "-32022" "$(resp "${OUT}" 13 | jq -r '.error.code')" "on: an empty version string"
for id in 4 5 6; do
	assert_eq "-32601" "$(resp "${OUT}" "${id}" | jq -r '.error.code')" "on: removed method (id ${id})"
done
case "$(text_of "${OUT}" 7)" in
*roots-from-env*) ;;
*) test_fail "on: a modern call should get the fallback roots: $(resp "${OUT}" 7)" ;;
esac
assert_eq "input_required" "$(resp "${OUT}" 8 | jq -r '.result.resultType')" "on: a question ends a modern call with input_required"
assert_eq "ui-yes" "$(text_of "${OUT}" 9 | tr -d '\n')" "on: the request's own UI capability"
if [ -n "$(jq -c 'select((.method? // "") | test("^(roots/list|elicitation/create)$"))' "${OUT}")" ]; then
	test_fail "on: the server sent a request to a modern client: $(grep '"method"' "${OUT}")"
fi

# --- Switch on, a legacy session in the same process ---------------------------
REQ="${TEST_TMPDIR}/mixed.ndjson"
{
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"extensions":{"io.modelcontextprotocol/ui":{}},"elicitation":{}},"clientInfo":{"name":"t","version":"1"}}}'
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
	modern tools/call 1 "$(call_params uicheck)"
	printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"uicheck","arguments":{}}}'
	modern tools/call 3 "$(call_params elicit)" '{"elicitation":{}}'
} >"${REQ}"
run "${TEST_TMPDIR}/mixed.out" "${REQ}" MCPBASH_MODERN_PROTOCOL=true
OUT="${TEST_TMPDIR}/mixed.out"
assert_eq "ui-no" "$(text_of "${OUT}" 1 | tr -d '\n')" "mixed: a modern call must not see the legacy client's UI capability"
assert_eq "ui-yes" "$(text_of "${OUT}" 2 | tr -d '\n')" "mixed: the legacy session keeps its UI capability"
assert_eq "input_required" "$(resp "${OUT}" 3 | jq -r '.result.resultType')" "mixed: a modern call's question is input_required"
if [ -n "$(jq -c 'select(.method? == "elicitation/create")' "${OUT}")" ]; then
	test_fail "mixed: a modern call's question reached the legacy client as elicitation/create"
fi

# --- initialize stays legacy whatever _meta it carries; inherited per-request
# variables (a nested mcp-bash gets a tool's) don't reach the legacy session --
REQ="${TEST_TMPDIR}/init.ndjson"
{
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"elicitation":{}},"clientInfo":{"name":"t","version":"1"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
	# A notification carrying modern _meta is still a legacy notification.
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
	printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"uicheck","arguments":{}}}'
	printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"elicit","arguments":{}}}'
} >"${REQ}"
run "${TEST_TMPDIR}/init.out" "${REQ}" MCPBASH_MODERN_PROTOCOL=true MCPBASH_PROTOCOL_ERA=modern MCPBASH_CLIENT_SUPPORTS_UI=1 MCPBASH_ELICITATION_TIMEOUT=1
OUT="${TEST_TMPDIR}/init.out"
assert_eq "2025-11-25" "$(jq -r 'select(.id == "init") | .result.protocolVersion' "${OUT}")" "initialize with modern _meta is a legacy initialize: $(jq -c 'select(.id == "init")' "${OUT}")"
assert_eq "ui-no" "$(text_of "${OUT}" 1 | tr -d '\n')" "an inherited MCPBASH_CLIENT_SUPPORTS_UI=1 must not reach the legacy session"
grep -q '"method":"elicitation/create"' "${OUT}" || test_fail "an inherited MCPBASH_PROTOCOL_ERA=modern turned off legacy elicitation"

# --- Switch on, cancelling a modern call in a process never initialized --------
REQ="${TEST_TMPDIR}/cancel.ndjson"
{
	modern tools/call 1 "$(call_params slow)"
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}'
	modern tools/list 2
} >"${REQ}"
start="${SECONDS}"
run "${TEST_TMPDIR}/cancel.out" "${REQ}" MCPBASH_MODERN_PROTOCOL=true
OUT="${TEST_TMPDIR}/cancel.out"
[ -z "$(resp "${OUT}" 1)" ] || test_fail "cancel: a cancelled call must get no response: $(resp "${OUT}" 1)"
resp "${OUT}" 2 | jq -e '.result.tools' >/dev/null || test_fail "cancel: the next call was not answered"
[ $((SECONDS - start)) -lt 15 ] || test_fail "cancel: the slow tool (sleep 30) was not stopped"

printf 'Modern core checks passed.\n'
