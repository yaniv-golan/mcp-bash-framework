#!/usr/bin/env bash
# Integration: several cancellations in a row don't stall request handling.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Several cancels in a row don't delay a following ping."

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
WORKSPACE="${TEST_TMPDIR}/cancel-nonblocking"
test_stage_workspace "${WORKSPACE}"

# Each cancel used to block the main loop for about 1s (TERM, sleep 1, KILL),
# one cancel at a time, so CALLS cancels delayed the next request by CALLS
# seconds. The ping must now answer in well under that; half of it leaves room
# for slow or loaded CI runners.
CALLS=10
MAX_PING_SECS=$((CALLS / 2))

PID_DIR="${WORKSPACE}/tool-pids"
mkdir -p "${PID_DIR}" "${WORKSPACE}/tools/slow"
cat <<'META' >"${WORKSPACE}/tools/slow/tool.meta.json"
{"name":"cancel-slow","description":"slow","inputSchema":{"type":"object","properties":{"n":{"type":"string"}}}}
META
# The tool records its pid so the test knows when every call is running, and
# so teardown can stop any that outlive their cancelled worker.
cat <<SH >"${WORKSPACE}/tools/slow/tool.sh"
#!/usr/bin/env bash
printf '%s' "\$\$" >"${PID_DIR}/\$\$"
sleep 30
echo "done"
SH
chmod +x "${WORKSPACE}/tools/slow/tool.sh"

stop_tools() {
	local f
	for f in "${PID_DIR}"/*; do
		[ -f "${f}" ] || continue
		kill "$(cat "${f}")" 2>/dev/null || true
	done
}

FIFO_ROOT="${WORKSPACE}/pipes"
mkdir -p "${FIFO_ROOT}"
PIPE_IN="${FIFO_ROOT}/in"
PIPE_OUT="${FIFO_ROOT}/out"
rm -f "${PIPE_IN}" "${PIPE_OUT}"
mkfifo "${PIPE_IN}" "${PIPE_OUT}"

(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" MCPBASH_TOOL_ALLOWLIST='*' ./bin/mcp-bash <"${PIPE_IN}" >"${PIPE_OUT}" &
	echo $! >"${WORKSPACE}/server.pid"
) || exit 1

exec 3>"${PIPE_IN}"
exec 4<"${PIPE_OUT}"

send() { printf '%s\n' "$1" >&3; }
# test_read_line keeps a line split across a read timeout; a plain `read -t`
# retry would drop it.
read_resp() {
	line=""
	if test_read_line 4 1; then
		line="${TEST_LINE}"
	fi
}
wait_for_id() {
	local want="$1" limit="$2" line deadline
	deadline=$((SECONDS + limit))
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		read_resp
		[ -z "${line}" ] && continue
		SEEN="${SEEN} $(printf '%s' "${line}" | jq -c '.id // .method' 2>/dev/null || printf 'unparsed')"
		if [ "$(printf '%s' "${line}" | jq -c '.id' 2>/dev/null || true)" = "${want}" ]; then
			return 0
		fi
	done
	return 1
}
SEEN=""
fail_and_stop() {
	stop_tools
	kill "$(cat "${WORKSPACE}/server.pid")" 2>/dev/null || true
	test_fail "$1 (messages seen:${SEEN:- none})"
}

# A cold start on a loaded runner can be slow.
send '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}'
wait_for_id '"init"' 30 || fail_and_stop "no initialize response"
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'

i=1
while [ "${i}" -le "${CALLS}" ]; do
	send "{\"jsonrpc\":\"2.0\",\"id\":\"c${i}\",\"method\":\"tools/call\",\"params\":{\"name\":\"cancel-slow\",\"arguments\":{\"n\":\"${i}\"}}}"
	i=$((i + 1))
done

# Wait until every tool is running, so each cancel has a live worker to stop.
started_deadline=$((SECONDS + 30))
while [ "$(find "${PID_DIR}" -type f | wc -l | tr -d ' ')" -lt "${CALLS}" ]; do
	if [ "${SECONDS}" -ge "${started_deadline}" ]; then
		fail_and_stop "only $(find "${PID_DIR}" -type f | wc -l | tr -d ' ') of ${CALLS} tools started"
	fi
	sleep 0.2
done

cancel_start=${SECONDS}
i=1
while [ "${i}" -le "${CALLS}" ]; do
	send "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\"c${i}\"}}"
	i=$((i + 1))
done
send '{"jsonrpc":"2.0","id":"ping","method":"ping"}'
wait_for_id '"ping"' 30 || fail_and_stop "no ping response after ${CALLS} cancels"
elapsed=$((SECONDS - cancel_start))
if [ "${elapsed}" -gt "${MAX_PING_SECS}" ]; then
	fail_and_stop "ping answered ${elapsed}s after ${CALLS} cancels (limit ${MAX_PING_SECS}s): cancels are blocking the main loop"
fi

send '{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}'
send '{"jsonrpc":"2.0","id":"exit","method":"exit"}'
exec 3>&-
while read -t 2 -r -u 4 _line; do :; done
exec 4<&-
server_pid="$(cat "${WORKSPACE}/server.pid")"
wait_deadline=$((SECONDS + 30))
while kill -0 "${server_pid}" 2>/dev/null && [ "${SECONDS}" -lt "${wait_deadline}" ]; do
	sleep 1
done
stop_tools
if kill -0 "${server_pid}" 2>/dev/null; then
	kill "${server_pid}" 2>/dev/null || true
	test_fail "server still running 30s after exit"
fi

printf 'Non-blocking cancellation test passed.\n'
