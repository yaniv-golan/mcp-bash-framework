#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="tools/list omits tools the operator allowlist blocks; instructions and stderr say so."

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
printf '%s\n' '{"name":"allowlist-test"}' >"${WS}/server.d/server.meta.json"
for t in alpha beta gamma; do
	mkdir -p "${WS}/tools/${t}"
	printf '{"name":"%s","description":"t","inputSchema":{"type":"object"}}\n' "${t}" >"${WS}/tools/${t}/tool.meta.json"
	printf '#!/usr/bin/env bash\nsource "${MCP_SDK}/tool-sdk.sh"\nmcp_result_text "%s"\n' "${t}" >"${WS}/tools/${t}/tool.sh"
	chmod +x "${WS}/tools/${t}/tool.sh"
done

REQ="${TEST_TMPDIR}/req.ndjson"
{
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
	printf '%s\n' '{"jsonrpc":"2.0","id":"list","method":"tools/list","params":{}}'
	printf '%s\n' '{"jsonrpc":"2.0","id":"list2","method":"tools/list","params":{}}'
	printf '%s\n' '{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"beta","arguments":{}}}'
} >"${REQ}"
names() { jq -c --arg id "${2:-list}" 'select(.id == $id) | [.result.tools[].name]' "$1"; }
total() { jq -r 'select(.id == "list") | .result._meta["mcpbash/total"]' "$1"; }
instr() { jq -r 'select(.id == "init") | .result.instructions // ""' "$1"; }
SENTENCE="Tools outside the server operator's allowlist (MCPBASH_TOOL_ALLOWLIST) are not listed"

printf ' -> a named allowlist: only those tools are listed\n'
OUT="${TEST_TMPDIR}/named.ndjson"
MCPBASH_TOOL_ALLOWLIST="alpha, gamma" test_run_mcp "${WS}" "${REQ}" "${OUT}"
assert_json_lines "${OUT}"
assert_eq '["alpha","gamma"]' "$(names "${OUT}")" "listed tools"
assert_eq "2" "$(total "${OUT}")" "total counts the listed tools"
case "$(instr "${OUT}")" in *"${SENTENCE}"*) ;; *) test_fail "no allowlist sentence: $(instr "${OUT}")" ;; esac
assert_eq "policy_denied" "$(jq -r 'select(.id == "call") | .result._meta["mcpbash/error"].type' "${OUT}")" "calling an unlisted tool"
# A warning log message names the unlisted tools, once per server.
test_assert_eq "$(jq -r 'select(.method == "notifications/message") | .params.data' "${OUT}" | grep -c 'not listed because MCPBASH_TOOL_ALLOWLIST does not allow them: beta')" "1"

printf ' -> "*": everything is listed, no sentence\n'
OUT="${TEST_TMPDIR}/all.ndjson"
MCPBASH_TOOL_ALLOWLIST="*" test_run_mcp "${WS}" "${REQ}" "${OUT}"
assert_eq '["alpha","beta","gamma"]' "$(names "${OUT}")" "all tools"
case "$(instr "${OUT}")" in *"${SENTENCE}"*) test_fail "sentence with '*'" ;; esac
if grep -q 'not listed because' "${OUT}"; then test_fail "log note with '*'"; fi

printf ' -> deny by default (no allowlist): nothing is listed\n'
OUT="${TEST_TMPDIR}/none.ndjson"
MCPBASH_TOOL_ALLOWLIST="" MCPBASH_TOOL_ALLOW_DEFAULT="" test_run_mcp "${WS}" "${REQ}" "${OUT}"
assert_eq '[]' "$(names "${OUT}")" "no tools"
case "$(instr "${OUT}")" in *"${SENTENCE}"*) ;; *) test_fail "deny by default: no sentence" ;; esac

printf ' -> MCPBASH_TOOL_ALLOW_DEFAULT=allow: everything is listed\n'
OUT="${TEST_TMPDIR}/default-allow.ndjson"
MCPBASH_TOOL_ALLOWLIST="" MCPBASH_TOOL_ALLOW_DEFAULT="allow" test_run_mcp "${WS}" "${REQ}" "${OUT}"
assert_eq '["alpha","beta","gamma"]' "$(names "${OUT}")" "allow by default"

printf ' -> a modern (2026-07-28) tools/list is filtered too\n'
MREQ="${TEST_TMPDIR}/modern.ndjson"
jq -cn '{jsonrpc: "2.0", id: "mlist", method: "tools/list", params: {_meta: {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}}}' >"${MREQ}"
OUT="${TEST_TMPDIR}/modern-out.ndjson"
MCPBASH_MODERN_PROTOCOL=true MCPBASH_TOOL_ALLOWLIST="beta" test_run_mcp "${WS}" "${MREQ}" "${OUT}"
assert_eq '["beta"]' "$(names "${OUT}" mlist)" "modern listing"

printf 'tools/list allowlist checks passed.\n'
