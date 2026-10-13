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
# With live progress on, the background flusher and the worker's final flush
# both send the stream; without a lock both could send the same line. A fast
# flusher makes that race likely (11 of 15 runs duplicated without the lock),
# so the live run repeats to catch it.
check_once() {
	local live="$1" run="$2"
	local out="${TEST_TMPDIR}/out.${live}.${run}.ndjson"
	MCPBASH_ENABLE_LIVE_PROGRESS="${live}" MCPBASH_PROGRESS_FLUSH_INTERVAL=0.05 MCPBASH_TOOL_ALLOWLIST='*' test_run_mcp "${WS}" "${REQ}" "${out}"
	assert_json_lines "${out}"
	assert_eq "1" "$(jq -r 'select(.method == "notifications/message" and .params.data == "hello-info") | 1' "${out}" | wc -l | tr -d ' ')" "tool log delivered once (live=${live}, run ${run})"
}
check_once false 1
for run in 1 2 3 4 5; do
	check_once true "${run}"
done

printf 'Live progress log checks passed.\n'
