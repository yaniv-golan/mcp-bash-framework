#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="A tool sees whether the client supports MCP Apps (mcp_client_supports_ui)."

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
mkdir -p "${WS}/server.d" "${WS}/tools/uicheck"
printf '%s\n' '{"name": "ui-capability"}' >"${WS}/server.d/server.meta.json"
printf '%s\n' '{"name":"uicheck","description":"t","inputSchema":{"type":"object"}}' >"${WS}/tools/uicheck/tool.meta.json"
cat >"${WS}/tools/uicheck/tool.sh" <<'SH'
#!/usr/bin/env bash
source "${MCP_SDK}/tool-sdk.sh"
source "${MCP_SDK}/ui-sdk.sh"
if mcp_client_supports_ui; then echo ui-yes; else echo ui-no; fi
SH
chmod +x "${WS}/tools/uicheck/tool.sh"

# session CAPS: the uicheck tool's answer for a client with capabilities CAPS.
session() {
	local caps="$1" req="${TEST_TMPDIR}/req.ndjson" out="${TEST_TMPDIR}/out.ndjson"
	{
		jq -cn --argjson c "${caps}" '{jsonrpc: "2.0", id: "init", method: "initialize", params: {protocolVersion: "2025-11-25", capabilities: $c, clientInfo: {name: "t", version: "1"}}}'
		printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
		printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"uicheck","arguments":{}}}'
	} >"${req}"
	MCPBASH_TOOL_ALLOWLIST='*' test_run_mcp "${WS}" "${req}" "${out}"
	jq -r 'select(.id == 1) | .result.content[0].text // empty' "${out}" | tr -d '\n'
}

assert_eq "ui-yes" "$(session '{"extensions":{"io.modelcontextprotocol/ui":{}}}')" "a client with the UI extension"
assert_eq "ui-no" "$(session '{}')" "a client without it"

# No client at all (run-tool): a value inherited from the environment, as an
# mcp-bash started by a tool would get, must not count as client support.
out="$(cd "${WS}" && MCPBASH_PROJECT_ROOT="${WS}" MCPBASH_TOOL_ALLOWLIST='*' MCPBASH_CLIENT_SUPPORTS_UI=1 ./bin/mcp-bash run-tool uicheck 2>/dev/null || true)"
assert_eq "ui-no" "$(printf '%s' "${out}" | jq -r '.content[0].text // empty' | tr -d '\n')" "run-tool with an inherited MCPBASH_CLIENT_SUPPORTS_UI=1"

printf 'Tool UI capability checks passed.\n'
