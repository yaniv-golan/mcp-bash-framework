#!/usr/bin/env bash
# Integration: stdin EOF after a cancellation still drains other in-flight calls.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="EOF after a cancel delivers other in-flight results and exits 0 with no workers left."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq

if [ "${IS_WINDOWS:-false}" = "true" ]; then
	printf 'Skipping cancel/EOF drain test on Windows.\n'
	exit 0
fi

# Real users run with the idle/orphan checks on, which selects the timed-read
# loop; CI mode turns them off and would hide this path.
unset MCPBASH_CI_MODE MCPBASH_IDLE_TIMEOUT_ENABLED MCPBASH_ORPHAN_CHECK_ENABLED

test_create_tmpdir
WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
WS="$(cd "${WS}" && pwd -P)"

# Each call records its pid, so the test can check none is left running.
mkdir -p "${WS}/tools/slow" "${WS}/pids"
cat <<'META' >"${WS}/tools/slow/tool.meta.json"
{"name":"drain.slow","description":"slow","inputSchema":{"type":"object","properties":{}}}
META
cat <<SH >"${WS}/tools/slow/tool.sh"
#!/usr/bin/env bash
printf '%s' "\$\$" >"${WS}/pids/\$\$"
sleep 5
echo "done"
SH
chmod +x "${WS}/tools/slow/tool.sh"

LIMIT=40
FAILURES=""

note_fail() {
	printf '  %s: FAIL (%s)\n' "$1" "$2"
	FAILURES="${FAILURES}$1: $2; "
}

run_case() {
	local shell_bin="$1"
	local fifo="${TEST_TMPDIR}/in.$$.${RANDOM}"
	local out="${TEST_TMPDIR}/out.$$.${RANDOM}"
	rm -f "${WS}/pids/"*
	mkfifo "${fifo}"
	(cd "${WS}" && MCPBASH_PROJECT_ROOT="${WS}" exec "${shell_bin}" ./bin/mcp-bash <"${fifo}" >"${out}" 2>/dev/null) &
	local pid=$!
	exec 7>"${fifo}"
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}' >&7
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&7
	printf '%s\n' '{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"drain.slow","arguments":{}}}' >&7
	printf '%s\n' '{"jsonrpc":"2.0","id":"b","method":"tools/call","params":{"name":"drain.slow","arguments":{}}}' >&7

	# Cancel only once both tools are running, then close stdin while "b" runs.
	local waited=0
	while [ "$(find "${WS}/pids" -type f | wc -l | tr -d ' ')" -lt 2 ] && [ "${waited}" -lt 150 ]; do
		sleep 0.1
		waited=$((waited + 1))
	done
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"a"}}' >&7
	exec 7>&-

	waited=0
	while kill -0 "${pid}" 2>/dev/null && [ "${waited}" -lt "${LIMIT}" ]; do
		sleep 1
		waited=$((waited + 1))
	done
	if kill -0 "${pid}" 2>/dev/null; then
		kill -KILL "${pid}" 2>/dev/null || true
		note_fail "${shell_bin}" "server still running ${LIMIT}s after stdin closed"
	fi
	local rc=0
	wait "${pid}" 2>/dev/null || rc=$?
	rm -f "${fifo}"

	local before="${FAILURES}"
	if [ "${rc}" -ne 0 ]; then
		note_fail "${shell_bin}" "server exited with status ${rc}"
	fi
	if ! jq -e -s 'any(.[]; .id == "b" and has("result"))' "${out}" >/dev/null 2>&1; then
		note_fail "${shell_bin}" "no result for the uncancelled call"
	fi
	if jq -e -s 'any(.[]; .id == "a")' "${out}" >/dev/null 2>&1; then
		note_fail "${shell_bin}" "the cancelled call returned a response"
	fi
	local tool_pid_file tool_pid
	for tool_pid_file in "${WS}/pids/"*; do
		[ -f "${tool_pid_file}" ] || continue
		tool_pid="$(cat "${tool_pid_file}")"
		if kill -0 "${tool_pid}" 2>/dev/null; then
			note_fail "${shell_bin}" "tool process ${tool_pid} still running after the server exited"
			kill -KILL "${tool_pid}" 2>/dev/null || true
		fi
	done
	rm -f "${out}"
	if [ "${before}" = "${FAILURES}" ]; then
		printf '  %s: ok (rc=%s)\n' "${shell_bin}" "${rc}"
	fi
}

shells="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" != "$(bash -c 'echo ${BASH_VERSINFO[0]}')" ]; then
	shells="bash /bin/bash"
fi
for shell_bin in ${shells}; do
	printf '%s (%s):\n' "${shell_bin}" "$("${shell_bin}" -c 'echo ${BASH_VERSION}')"
	run_case "${shell_bin}"
done

if [ -n "${FAILURES}" ]; then
	test_fail "${FAILURES}"
fi
printf 'Cancel then EOF drain test passed.\n'
