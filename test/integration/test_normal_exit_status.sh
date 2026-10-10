#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Normal server exits (EOF, shutdown/exit, idle timeout) keep status 0."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

# The EXIT trap treats a zero status as a failure unless the exit was intended
# (bash 3.2 reports 0 after a fatal shell error). These are the intended ones.

test_create_tmpdir
unset MCPBASH_KEEP_LOGS MCPBASH_PRESERVE_STATE MCPBASH_LOG_DIR

WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
mkdir -p "${WS}/server.d"
printf '%s\n' '{"name": "exit-status"}' >"${WS}/server.d/server.meta.json"

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

server_status() {
	local status=0
	(cd "${WS}" && bash ./bin/mcp-bash >/dev/null 2>"${TEST_TMPDIR}/err.log") || status=$?
	printf '%s' "${status}"
}

for mode in ci real; do
	if [ "${mode}" = "ci" ]; then
		export MCPBASH_CI_MODE=true
	else
		unset MCPBASH_CI_MODE
	fi

	printf ' -> end of input (%s mode)\n' "${mode}"
	status="$(printf '%s\n' "${INIT}" | server_status)"
	assert_eq "0" "${status}" "EOF exit status (${mode})"

	printf ' -> shutdown then exit (%s mode)\n' "${mode}"
	status="$(printf '%s\n%s\n%s\n' "${INIT}" \
		'{"jsonrpc":"2.0","id":3,"method":"shutdown"}' \
		'{"jsonrpc":"2.0","method":"exit"}' | server_status)"
	assert_eq "0" "${status}" "shutdown/exit status (${mode})"
done

printf ' -> idle timeout (real mode)\n'
unset MCPBASH_CI_MODE
fifo="${TEST_TMPDIR}/idle.fifo"
mkfifo "${fifo}"
status=0
(cd "${WS}" && MCPBASH_IDLE_TIMEOUT=2 bash ./bin/mcp-bash <"${fifo}" >/dev/null 2>"${TEST_TMPDIR}/err.log") &
pid=$!
exec 7>"${fifo}"
printf '%s\n' "${INIT}" >&7
waited=0
while kill -0 "${pid}" 2>/dev/null; do
	if [ "${waited}" -ge 30 ]; then
		kill -KILL "${pid}" 2>/dev/null || true
		test_fail "server did not exit on idle timeout"
	fi
	sleep 1
	waited=$((waited + 1))
done
wait "${pid}" || status=$?
exec 7>&-
assert_eq "0" "${status}" "idle timeout exit status"

printf 'Normal exit status test passed.\n'
