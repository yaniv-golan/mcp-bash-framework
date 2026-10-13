#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Modern (2026-07-28) logging: notifications/message only when a request asks, at its level."

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
mkdir -p "${WS}/server.d" "${WS}/tools/logger" "${WS}/tools/broken"
printf '%s\n' '{"name": "modern-logging"}' >"${WS}/server.d/server.meta.json"
printf '%s\n' '{"name":"logger","description":"t","inputSchema":{"type":"object"}}' >"${WS}/tools/logger/tool.meta.json"
cat >"${WS}/tools/logger/tool.sh" <<'SH'
#!/usr/bin/env bash
source "${MCP_SDK}/tool-sdk.sh"
mcp_log info t '"hello-info"'
mcp_log error t '"hello-error"'
echo ok
SH
chmod +x "${WS}/tools/logger/tool.sh"
# A tool the registry warns about: a registration warning must not reach a
# modern client as an unsolicited notification.
printf '%s\n' '{"name":"bad name with spaces","description":"t","inputSchema":{"type":"object"}}' >"${WS}/tools/broken/tool.meta.json"
printf '#!/usr/bin/env bash\necho x\n' >"${WS}/tools/broken/tool.sh"
chmod +x "${WS}/tools/broken/tool.sh"

# call ID [LOG_LEVEL]: a modern tools/call of the logger tool.
call() {
	local id="$1" level="${2:-}"
	jq -cn --argjson id "${id}" --arg l "${level}" '
		{jsonrpc: "2.0", id: $id, method: "tools/call", params: {name: "logger", arguments: {}, _meta: (
			{"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}
			+ (if $l != "" then {"io.modelcontextprotocol/logLevel": $l} else {} end))}}'
}
# logs OUT: the data of every notifications/message, sorted.
logs() { jq -r 'select(.method == "notifications/message") | .params.data | tostring' "$1" | LC_ALL=C sort | tr '\n' ' '; }

for live in false true; do
	for case_ in "none:" "info:hello-error hello-info " "error:hello-error "; do
		level="${case_%%:*}"
		want="${case_#*:}"
		[ "${level}" = "none" ] && level=""
		REQ="${TEST_TMPDIR}/req.ndjson"
		OUT="${TEST_TMPDIR}/out.ndjson"
		call 1 "${level}" >"${REQ}"
		MCPBASH_MODERN_PROTOCOL=true MCPBASH_TOOL_ALLOWLIST='*' MCPBASH_ENABLE_LIVE_PROGRESS="${live}" MCPBASH_LOG_LEVEL=debug \
			test_run_mcp "${WS}" "${REQ}" "${OUT}"
		assert_json_lines "${OUT}"
		jq -e 'select(.id == 1) | .result' "${OUT}" >/dev/null || test_fail "no result (live=${live}, level=${level:-none})"
		assert_eq "${want}" "$(logs "${OUT}")" "log notifications (live=${live}, level=${level:-none})"
	done
done

printf 'Modern logging checks passed.\n'
