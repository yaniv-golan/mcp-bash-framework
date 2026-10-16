#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="mcp_elicit_confirm never takes --arg when the client can ask, even for a call the server can't route a question for."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

WORKROOT="${TEST_TMPDIR}/unrouted"
test_stage_workspace "${WORKROOT}"

mkdir -p "${WORKROOT}/tools/confirm"
cat <<'META' >"${WORKROOT}/tools/confirm/tool.meta.json"
{
  "name": "confirm.test",
  "description": "Confirms with --arg go",
  "inputSchema": {"type": "object", "properties": {"go": {"type": "boolean"}}}
}
META
cat <<'SH' >"${WORKROOT}/tools/confirm/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
if mcp_elicit_confirm --arg go "Delete everything?" 2>/dev/null; then
	mcp_result_text "confirmed"
	exit 0
fi
mcp_result_text "not-confirmed:${MCP_ELICIT_ACTION}"
SH
chmod +x "${WORKROOT}/tools/confirm/tool.sh"

# A tools/call with "id": null gets no worker key, so the server has no
# question files for it. The client said it can ask, so the model's go: true
# must not stand in for the user.
response="$(
	cd "${WORKROOT}" && {
		printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"elicitation":{}}}}'
		printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
		printf '%s\n' '{"jsonrpc":"2.0","id":null,"method":"tools/call","params":{"name":"confirm.test","arguments":{"go":true}}}'
		sleep 8
	} | MCPBASH_PROJECT_ROOT="${WORKROOT}" ./bin/mcp-bash 2>/dev/null | jq -c 'select(.id == null and has("result"))'
)"
[ -n "${response}" ] || test_fail "no tools/call response"
text="$(printf '%s' "${response}" | jq -r '.result.content[0].text')"
assert_eq "not-confirmed:unavailable" "${text}" "confirm took --arg although the client can ask"
printf 'unrouted confirm passed\n'
