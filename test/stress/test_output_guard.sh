#!/usr/bin/env bash
# Stress: ensure large tool output is guarded and returns an error.

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
WORKSPACE="${TEST_TMPDIR}/guard"
test_stage_workspace "${WORKSPACE}"

mkdir -p "${WORKSPACE}/tools/big"
cat <<'META' >"${WORKSPACE}/tools/big/tool.meta.json"
{"name": "stress.big", "description": "Emit huge output", "arguments": {"type": "object", "properties": {}}}
META
cat <<'SH' >"${WORKSPACE}/tools/big/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
yes A | head -c 15000000
SH
chmod +x "${WORKSPACE}/tools/big/tool.sh"

REQS="${WORKSPACE}/requests.ndjson"
cat <<'JSON' >"${REQS}"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"stress.big","arguments":{}}}
JSON

RESP="${WORKSPACE}/responses.ndjson"
(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" MCPBASH_MAX_TOOL_OUTPUT_SIZE=1048576 ./bin/mcp-bash <"${REQS}" >"${RESP}"
) || true

if ! jq -e 'select(.id=="call") | has("error")' "${RESP}" >/dev/null; then
	echo "Expected output guard error for big tool" >&2
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

echo "Output guard stress passed."
