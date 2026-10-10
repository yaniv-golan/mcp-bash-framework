#!/usr/bin/env bash
# Integration: a timed-out or cancelled tool is stopped, with its children.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Timeout and cancel send TERM to the tool (its trap runs) and stop the processes it started."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

case "$(uname -s 2>/dev/null)" in
MINGW* | MSYS* | CYGWIN*)
	# Git Bash has no process groups or ps -o; signals reach only the tool pid.
	printf 'Skipping tool termination test on Windows.\n'
	exit 0
	;;
esac

test_require_command jq

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/term"
test_stage_workspace "${WORKSPACE}"
MARKS="${TEST_TMPDIR}/marks"
mkdir -p "${MARKS}"

# The tool records its pid and its child's pid, writes a marker when its TERM
# trap runs, and would otherwise wait 300s on a background sleep.
make_tool() {
	local dir="$1" name="$2" timeout="$3" tag="$4"
	mkdir -p "${WORKSPACE}/tools/${dir}"
	cat <<META >"${WORKSPACE}/tools/${dir}/tool.meta.json"
{"name":"${name}","description":"slow","timeoutSecs":${timeout},"inputSchema":{"type":"object","properties":{}}}
META
	cat <<SH >"${WORKSPACE}/tools/${dir}/tool.sh"
#!/usr/bin/env bash
trap 'echo term >"${MARKS}/${tag}.term"; exit 143' TERM
sleep 300 &
child=\$!
echo "\$\$ \${child}" >"${MARKS}/${tag}.pids"
wait "\${child}"
echo done
SH
	chmod +x "${WORKSPACE}/tools/${dir}/tool.sh"
}
make_tool timeout term.timeout 2 timeout
make_tool cancel term.cancel 60 cancel

leftovers=""
cleanup_leftovers() {
	local p
	for p in ${leftovers}; do
		kill -KILL "${p}" 2>/dev/null || true
	done
}
trap cleanup_leftovers EXIT

# Wait up to $2 seconds for every pid in $1 to exit.
wait_gone() {
	local pids="$1" limit="$2" p alive
	local deadline=$((SECONDS + limit))
	while :; do
		alive=""
		for p in ${pids}; do
			kill -0 "${p}" 2>/dev/null && alive="${alive} ${p}"
		done
		[ -z "${alive}" ] && return 0
		if [ "${SECONDS}" -ge "${deadline}" ]; then
			printf '%s' "${alive}"
			return 1
		fi
		sleep 0.2
	done
}

wait_file() {
	local file="$1" limit="$2"
	local deadline=$((SECONDS + limit))
	while [ ! -s "${file}" ]; do
		[ "${SECONDS}" -ge "${deadline}" ] && return 1
		sleep 0.1
	done
}

FIFO_ROOT="${WORKSPACE}/pipes"
mkdir -p "${FIFO_ROOT}"
PIPE_IN="${FIFO_ROOT}/in"
PIPE_OUT="${FIFO_ROOT}/out"
mkfifo "${PIPE_IN}" "${PIPE_OUT}"

(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_TOOL_ALLOWLIST='*' MCPBASH_PROJECT_ROOT="${WORKSPACE}" ./bin/mcp-bash <"${PIPE_IN}" >"${PIPE_OUT}" 2>"${WORKSPACE}/server.err" &
	echo $! >"${WORKSPACE}/server.pid"
) || exit 1
exec 3>"${PIPE_IN}"
exec 4<"${PIPE_OUT}"
send() { printf '%s\n' "$1" >&3; }

# Read responses until one has id $1, or $2 seconds pass.
wait_id() {
	local want="$1" limit="$2"
	local deadline=$((SECONDS + limit))
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		if test_read_line 4 1 && [ "$(printf '%s' "${TEST_LINE}" | jq -c '.id' 2>/dev/null || true)" = "${want}" ]; then
			return 0
		fi
	done
	return 1
}

send '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}'
wait_id '"init"' 20 || test_fail "no initialize response"
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'

# 1) Timeout: the tool gets TERM (its trap runs) and its child is stopped.
send '{"jsonrpc":"2.0","id":"t","method":"tools/call","params":{"name":"term.timeout","arguments":{}}}'
wait_file "${MARKS}/timeout.pids" 20 || test_fail "timeout tool never started"
wait_id '"t"' 30 || test_fail "no response to the timed-out call"
read -r tool_pid child_pid <"${MARKS}/timeout.pids"
leftovers="${leftovers} ${tool_pid} ${child_pid}"
if ! gone="$(wait_gone "${tool_pid} ${child_pid}" 10)"; then
	test_fail "timed-out tool left processes running:${gone}"
fi
[ -f "${MARKS}/timeout.term" ] || test_fail "timed-out tool never received TERM (its trap did not run)"

# 2) Cancel: the tool gets TERM (its trap runs) and its child is stopped.
send '{"jsonrpc":"2.0","id":"c","method":"tools/call","params":{"name":"term.cancel","arguments":{}}}'
wait_file "${MARKS}/cancel.pids" 20 || test_fail "cancel tool never started"
send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"c"}}'
read -r tool_pid child_pid <"${MARKS}/cancel.pids"
leftovers="${leftovers} ${tool_pid} ${child_pid}"
if ! gone="$(wait_gone "${tool_pid} ${child_pid}" 10)"; then
	test_fail "cancelled tool left processes running:${gone}"
fi
[ -f "${MARKS}/cancel.term" ] || test_fail "cancelled tool never received TERM (its trap did not run)"

exec 3>&-
server_pid="$(cat "${WORKSPACE}/server.pid")"
wait_gone "${server_pid}" 20 >/dev/null || test_fail "server did not exit after stdin closed"
# The delayed cancel escalation must not write into the removed state dir.
sleep 2
if grep -q 'No such file' "${WORKSPACE}/server.err"; then
	test_fail "server stderr has file errors: $(grep 'No such file' "${WORKSPACE}/server.err" | head -3)"
fi

printf 'Timed-out and cancelled tools were stopped with their children.\n'
