#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Server exits promptly when stdin closes (FIFO, pipe, socketpair), outside CI mode."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

# Real users run with the idle/orphan checks on, which selects the timed-read
# loop; CI mode turns them off and would hide this path.
unset MCPBASH_CI_MODE MCPBASH_IDLE_TIMEOUT_ENABLED MCPBASH_ORPHAN_CHECK_ENABLED

WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
mkdir -p "${WS}/server.d"
printf '%s\n' '{"name": "eof-shutdown"}' >"${WS}/server.d/server.meta.json"
INIT='{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}'

LIMIT=15

# Wait for a server pid to exit; kill it (and fail) if it outlives LIMIT.
wait_for_exit() {
	local pid="$1" label="$2" waited=0
	while kill -0 "${pid}" 2>/dev/null; do
		if [ "${waited}" -ge "${LIMIT}" ]; then
			kill -KILL "${pid}" 2>/dev/null || true
			test_fail "${label}: server still running ${LIMIT}s after stdin closed"
		fi
		sleep 1
		waited=$((waited + 1))
	done
	wait "${pid}" 2>/dev/null || true
	printf '  %s: exited after ~%ss\n' "${label}" "${waited}"
}

run_fifo() {
	local shell_bin="$1" fifo="${TEST_TMPDIR}/in.$$.${RANDOM}"
	mkfifo "${fifo}"
	(cd "${WS}" && exec "${shell_bin}" ./bin/mcp-bash <"${fifo}" >/dev/null 2>&1) &
	local pid=$!
	exec 7>"${fifo}"
	printf '%s\n' "${INIT}" >&7
	sleep 1
	exec 7>&-
	wait_for_exit "${pid}" "${shell_bin} fifo"
	rm -f "${fifo}"
}

run_pipe() {
	local shell_bin="$1"
	{ printf '%s\n' "${INIT}"; sleep 1; } | (cd "${WS}" && exec "${shell_bin}" ./bin/mcp-bash >/dev/null 2>&1) &
	wait_for_exit "$!" "${shell_bin} pipe"
}

run_socketpair() {
	local shell_bin="$1"
	command -v python3 >/dev/null 2>&1 || {
		printf '  %s socketpair: skipped (python3 not available)\n' "${shell_bin}"
		return 0
	}
	# Node/libuv (Claude Desktop) gives servers socketpair stdio; emulate it.
	python3 - "${shell_bin}" "${WS}" "${INIT}" "${LIMIT}" <<'PY'
import os, socket, subprocess, sys, time
shell_bin, ws, init, limit = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
parent, child = socket.socketpair()
proc = subprocess.Popen([shell_bin, "./bin/mcp-bash"], cwd=ws, stdin=child,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
child.close()
parent.sendall((init + "\n").encode())
time.sleep(1)
parent.shutdown(socket.SHUT_WR)
parent.close()
start = time.time()
try:
    proc.wait(timeout=limit)
    print(f"  {shell_bin} socketpair: exited after ~{int(time.time() - start)}s")
except subprocess.TimeoutExpired:
    proc.kill()
    print(f"ASSERTION FAILED: {shell_bin} socketpair: server still running {limit}s after stdin closed")
    sys.exit(1)
PY
}

shells="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" != "$(bash -c 'echo ${BASH_VERSINFO[0]}')" ]; then
	shells="bash /bin/bash"
fi
for shell_bin in ${shells}; do
	printf '%s (%s):\n' "${shell_bin}" "$("${shell_bin}" -c 'echo ${BASH_VERSION}')"
	run_fifo "${shell_bin}"
	run_pipe "${shell_bin}"
	run_socketpair "${shell_bin}"
done

printf 'stdin EOF shutdown test passed.\n'
