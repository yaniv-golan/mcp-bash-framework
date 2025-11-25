#!/usr/bin/env bash
# Stress: validate long-running tool timeout and progress behavior.

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
WORKSPACE="${TEST_TMPDIR}/long"
test_stage_workspace "${WORKSPACE}"

mkdir -p "${WORKSPACE}/tools"
cat <<'META' >"${WORKSPACE}/tools/slow.meta.json"
{"name": "stress.slow", "description": "Sleeps and emits progress", "arguments": {"type": "object", "properties": {}}, "timeoutSecs": 2}
META
cat <<'SH' >"${WORKSPACE}/tools/slow.sh"
#!/usr/bin/env bash
set -euo pipefail
. "${MCP_SDK}/tool-sdk.sh"
mcp_progress 10 "starting"
sleep 5
printf 'done'
SH
chmod +x "${WORKSPACE}/tools/slow.sh"

REQS="${WORKSPACE}/requests.ndjson"
cat <<'JSON' >"${REQS}"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"stress.slow","arguments":{},"timeoutSecs":1}}
JSON

RESP="${WORKSPACE}/responses.ndjson"
start=$(date +%s)
set +e
(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" MCPBASH_DEFAULT_TOOL_TIMEOUT=1 ./bin/mcp-bash <"${REQS}" >"${RESP}"
)
status=$?
set -e
end=$(date +%s)
elapsed=$((end - start))

if [ "${elapsed}" -ge 4 ]; then
	echo "Long-running tool did not stop within timeout window (elapsed ${elapsed}s)" >&2
	cat "${RESP}" >&2
	exit 1
fi

if ! jq -e 'select(.id=="init")' "${RESP}" >/dev/null; then
	echo "Missing init response in long-running stress" >&2
	cat "${RESP}" >&2
	exit 1
fi

# Send a graceful shutdown to avoid watchdog chatter
cat <<'JSON' >"${WORKSPACE}/shutdown.ndjson"
{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}
{"jsonrpc":"2.0","id":"exit","method":"exit"}
JSON
(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" MCPBASH_SHUTDOWN_TIMEOUT=0 ./bin/mcp-bash <"${WORKSPACE}/shutdown.ndjson" >/dev/null
) || true

echo "Long-running stress passed."
