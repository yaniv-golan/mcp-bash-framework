#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="A tool timeout fires when ps can't report process groups."
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
mkdir -p "${WS}/tools/slow" "${WS}/server.d"
printf '%s\n' '{"name": "timeout-without-ps"}' >"${WS}/server.d/server.meta.json"
printf '%s\n' '{"name": "slow", "description": "Sleeps", "inputSchema": {"type": "object", "properties": {}}, "timeoutSecs": 2}' >"${WS}/tools/slow/tool.meta.json"
printf '#!/usr/bin/env bash\nexec sleep 3017\n' >"${WS}/tools/slow/tool.sh"
chmod +x "${WS}/tools/slow/tool.sh"
chmod -R go-w "${WS}"
trap 'pkill -f "sleep 3017$" 2>/dev/null || true' EXIT

# A ps that can't answer (as on some minimal systems). Where /proc gives the
# process group (Linux), the server doesn't need ps for it, so this fails
# without the fix only where it does (macOS).
STUB="${TEST_TMPDIR}/stub"
mkdir -p "${STUB}"
printf '#!/bin/sh\nexit 1\n' >"${STUB}/ps"
chmod +x "${STUB}/ps"

cat >"${WS}/requests.ndjson" <<'JSON'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"slow","arguments":{}}}
JSON
start=${SECONDS}
# If the timeout never fires, end the tool after 30s so the test fails
# instead of waiting on it.
STOP="${TEST_TMPDIR}/stop-guard"
(
	n=0
	while [ "${n}" -lt 300 ] && [ ! -e "${STOP}" ]; do
		sleep 0.1
		n=$((n + 1))
	done
	[ -e "${STOP}" ] || pkill -f "sleep 3017$" 2>/dev/null || true
) &
guard=$!
PATH="${STUB}:${PATH}" MCPBASH_TOOL_ALLOWLIST=slow test_run_mcp "${WS}" "${WS}/requests.ndjson" "${WS}/responses.ndjson" || true
elapsed=$((SECONDS - start))
: >"${STOP}"
wait "${guard}" 2>/dev/null || true
resp="$(jq -c 'select(.id=="call")' "${WS}/responses.ndjson")"
[ -n "${resp}" ] || test_fail "no answer to the call"
printf '%s' "${resp}" | jq -e '.result.isError == true' >/dev/null || test_fail "not an error result: ${resp}"
case "$(printf '%s' "${resp}" | jq -r '.result.content[0].text')" in
*"timed out"* | *timeout*) ;;
*) test_fail "not a timeout: ${resp}" ;;
esac
[ "${elapsed}" -lt 25 ] || test_fail "the timeout took ${elapsed}s"
if pgrep -f "sleep 3017$" >/dev/null 2>&1; then
	test_fail "the timed-out tool is still running"
fi
printf 'Timeout without ps passed (%ss).\n' "${elapsed}"
