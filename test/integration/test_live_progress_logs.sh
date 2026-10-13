#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Tool log notifications are delivered with live progress on (MCPBASH_ENABLE_LIVE_PROGRESS)."

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
mkdir -p "${WS}/server.d" "${WS}/tools/logger"
printf '%s\n' '{"name": "live-logs"}' >"${WS}/server.d/server.meta.json"
printf '%s\n' '{"name":"logger","description":"t","inputSchema":{"type":"object"}}' >"${WS}/tools/logger/tool.meta.json"
cat >"${WS}/tools/logger/tool.sh" <<'SH'
#!/usr/bin/env bash
source "${MCP_SDK}/tool-sdk.sh"
mcp_log info t '"hello-info"'
echo ok
SH
chmod +x "${WS}/tools/logger/tool.sh"

REQ="${TEST_TMPDIR}/req.ndjson"
{
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
	printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"logger","arguments":{}}}'
} >"${REQ}"
# The live flusher and the worker's final flush race for the same lines:
# repeat the live run so a line sent twice shows up.
for live in false true true true true true; do
	OUT="${TEST_TMPDIR}/out.${live}.ndjson"
	MCPBASH_ENABLE_LIVE_PROGRESS="${live}" MCPBASH_LOG_LEVEL=debug MCPBASH_TOOL_ALLOWLIST='*' test_run_mcp "${WS}" "${REQ}" "${OUT}"
	assert_json_lines "${OUT}"
	assert_eq "1" "$(jq -r 'select(.method == "notifications/message" and .params.data == "hello-info") | 1' "${OUT}" | wc -l | tr -d ' ')" "tool log delivered once (live=${live})"
done

printf 'Live progress log checks passed.\n'
