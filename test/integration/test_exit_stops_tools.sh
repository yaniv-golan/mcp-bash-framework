#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Running tools are stopped when the server exits on a signal, a closed stdout or a dead parent."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq

case "$(uname -s 2>/dev/null)" in
CYGWIN* | MINGW* | MSYS*)
	printf 'SKIP: needs FIFOs and POSIX process groups\n'
	exit 0
	;;
esac

test_create_tmpdir
WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
mkdir -p "${WS}/server.d"
printf '%s\n' '{"name": "exit-stops-tools"}' >"${WS}/server.d/server.meta.json"

# Each case's tool sleeps for a distinct number of seconds, so the test can
# find exactly its process.
make_tool() {
	local name="$1" secs="$2"
	mkdir -p "${WS}/tools/${name}"
	printf '{"name": "%s", "description": "Runs %ss", "inputSchema": {"type": "object", "properties": {}}, "timeoutSecs": 9000}\n' "${name}" "${secs}" >"${WS}/tools/${name}/tool.meta.json"
	printf '#!/usr/bin/env bash\nexec sleep %s\n' "${secs}" >"${WS}/tools/${name}/tool.sh"
	chmod +x "${WS}/tools/${name}/tool.sh"
}
SIGTERM_SECS=7311
# Started by a tool's TERM handler, which then exits: stopped by the KILL.
TERM_LEFT_SECS=7316
KILL_LEFT_SECS=7317
STDOUT_SECS=7312
ORPHAN_SECS=7313
KILL_SECS=7314
ZOMBIE_SECS=7315
# A tool whose TERM handler starts a child of its own and exits.
make_leaver() {
	local name="$1" secs="$2" left="$3"
	mkdir -p "${WS}/tools/${name}"
	printf '{"name": "%s", "description": "Runs %ss", "inputSchema": {"type": "object", "properties": {}}, "timeoutSecs": 9000}\n' "${name}" "${secs}" >"${WS}/tools/${name}/tool.meta.json"
	printf '#!/usr/bin/env bash\ntrap "sleep %s & exit 0" TERM\nsleep %s &\nwait $!\n' "${left}" "${secs}" >"${WS}/tools/${name}/tool.sh"
	chmod +x "${WS}/tools/${name}/tool.sh"
}
make_leaver long-term "${SIGTERM_SECS}" "${TERM_LEFT_SECS}"
make_tool long-stdout "${STDOUT_SECS}"
make_tool long-orphan "${ORPHAN_SECS}"
make_leaver long-kill "${KILL_SECS}" "${KILL_LEFT_SECS}"
make_tool long-zombie "${ZOMBIE_SECS}"
make_tool slow 2
chmod -R go-w "${WS}"

trap '' PIPE
tool_running() { pgrep -f "sleep $1\$" >/dev/null 2>&1; }
cleanup_tools() {
	pkill -f "sleep (${SIGTERM_SECS}|${STDOUT_SECS}|${ORPHAN_SECS}|${KILL_SECS}|${ZOMBIE_SECS}|${TERM_LEFT_SECS}|${KILL_LEFT_SECS})\$" 2>/dev/null || true
}
trap cleanup_tools EXIT

# $1: tool seconds; waits up to 30s for the tool to start (slow under a loaded machine).
wait_tool_started() {
	local secs="$1" n=0
	while ! tool_running "${secs}"; do
		n=$((n + 1))
		[ "${n}" -lt 300 ] || test_fail "tool sleep ${secs} never started"
		sleep 0.1
	done
}
# $1: label; $2: server pid; $3: tool seconds. The server must exit and take
# the tool with it within 10s.
expect_stopped() {
	local label="$1" server="$2" secs="$3" n=0 server_gone=""
	while kill -0 "${server}" 2>/dev/null || tool_running "${secs}"; do
		if [ -z "${server_gone}" ] && ! kill -0 "${server}" 2>/dev/null; then
			server_gone="${n}"
		fi
		n=$((n + 1))
		if [ "${n}" -ge 100 ]; then
			if [ -z "${server_gone}" ]; then
				kill -KILL "${server}" 2>/dev/null || true
				test_fail "${label}: server still running after 10s"
			fi
			test_fail "${label}: tool still running 10s after the server exited"
		fi
		sleep 0.1
	done
	printf ' -> %s: server and tool stopped within %s.%ss\n' "${label}" "$((n / 10))" "$((n % 10))"
}

# $1: label; $2: seconds of the child a TERM handler left: it must be gone
# within 10s.
expect_left_gone() {
	local label="$1" secs="$2" n=0
	while tool_running "${secs}"; do
		n=$((n + 1))
		[ "${n}" -lt 100 ] || test_fail "${label}: a child the tool's TERM handler started is still running"
		sleep 0.1
	done
}

INIT='{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}'
INITIALIZED='{"jsonrpc":"2.0","method":"notifications/initialized"}'
call() { printf '{"jsonrpc":"2.0","id":"%s","method":"tools/call","params":{"name":"%s","arguments":{}}}' "$1" "$2"; }
ALLOW='long-term long-stdout long-orphan long-kill long-zombie slow'

# 1) The host sends SIGTERM while a tool runs.
in1="${TEST_TMPDIR}/term.in"
mkfifo "${in1}"
(cd "${WS}" && MCPBASH_TOOL_ALLOWLIST="${ALLOW}" exec bash ./bin/mcp-bash <"${in1}" >/dev/null 2>"${TEST_TMPDIR}/term.err") &
server=$!
exec 7>"${in1}"
printf '%s\n%s\n%s\n' "${INIT}" "${INITIALIZED}" "$(call c1 long-term)" >&7
wait_tool_started "${SIGTERM_SECS}"
kill -TERM "${server}"
expect_stopped "host SIGTERM" "${server}" "${SIGTERM_SECS}"
expect_left_gone "host SIGTERM" "${TERM_LEFT_SECS}"
exec 7>&-
wait "${server}" 2>/dev/null || true

# 2) The client stops reading; a second tool's result then fails to write.
in2="${TEST_TMPDIR}/stdout.in"
out2="${TEST_TMPDIR}/stdout.out"
mkfifo "${in2}" "${out2}"
(cd "${WS}" && MCPBASH_TOOL_ALLOWLIST="${ALLOW}" exec bash ./bin/mcp-bash <"${in2}" >"${out2}" 2>"${TEST_TMPDIR}/stdout.err") &
server=$!
exec 7>"${in2}"
exec 8<"${out2}"
printf '%s\n' "${INIT}" >&7
IFS= read -r -t 10 line <&8 || test_fail "closed stdout: no initialize response"
printf '%s\n%s\n%s\n' "${INITIALIZED}" "$(call c1 long-stdout)" "$(call c2 slow)" >&7
wait_tool_started "${STDOUT_SECS}"
sleep 0.5
while IFS= read -r -t 1 line <&8; do :; done
exec 8<&-
expect_stopped "closed stdout" "${server}" "${STDOUT_SECS}"
exec 7>&-
wait "${server}" 2>/dev/null || true

# 3) The server's parent dies while a tool runs (stdin stays open).
in3="${TEST_TMPDIR}/orphan.in"
mkfifo "${in3}"
exec 7<>"${in3}"
# A simple command started with & is this subshell's direct child, so the
# subshell is the server's parent. Orphan detection runs only in the timed
# read loop, which CI mode turns off.
(
	cd "${WS}" || exit 1
	MCPBASH_CI_MODE=false MCPBASH_TOOL_ALLOWLIST="${ALLOW}" MCPBASH_ORPHAN_CHECK_INTERVAL=1 MCPBASH_IDLE_TIMEOUT=0 \
		bash ./bin/mcp-bash <"${in3}" >/dev/null 2>"${TEST_TMPDIR}/orphan.err" &
	printf '%s' "$!" >"${TEST_TMPDIR}/orphan.pid"
	sleep 4
) &
parent=$!
while [ ! -s "${TEST_TMPDIR}/orphan.pid" ]; do sleep 0.1; done
server="$(cat "${TEST_TMPDIR}/orphan.pid")"
printf '%s\n%s\n%s\n' "${INIT}" "${INITIALIZED}" "$(call c1 long-orphan)" >&7
wait_tool_started "${ORPHAN_SECS}"
wait "${parent}" 2>/dev/null || true
expect_stopped "dead parent" "${server}" "${ORPHAN_SECS}"
exec 7>&-

# A SIGKILLed server runs no cleanup of its own: what it started must still
# stop, and the state dir it made must go. Its own temp root shows leftovers.
unset MCPBASH_KEEP_LOGS MCPBASH_PRESERVE_STATE MCPBASH_LOG_DIR
# $1: label; $2: tool seconds; $3: temp root. The tool must stop within 10s,
# and no state dir may be left.
expect_tool_and_state_gone() {
	local label="$1" secs="$2" root="$3" n=0
	while tool_running "${secs}"; do
		n=$((n + 1))
		[ "${n}" -lt 100 ] || test_fail "${label}: tool still running 10s after the server was killed"
		sleep 0.1
	done
	while [ -n "$(find "${root}" -maxdepth 1 -name 'mcpbash.state.*' 2>/dev/null)" ]; do
		n=$((n + 1))
		[ "${n}" -lt 150 ] || test_fail "${label}: state dir left behind: $(find "${root}" -maxdepth 1 -name 'mcpbash.state.*')"
		sleep 0.1
	done
	printf ' -> %s: tool stopped and state removed within %s.%ss\n' "${label}" "$((n / 10))" "$((n % 10))"
}

# 4) The host SIGKILLs the server (and reaps it) while a tool runs.
root4="${TEST_TMPDIR}/kill-root"
mkdir -p "${root4}"
in4="${TEST_TMPDIR}/kill.in"
mkfifo "${in4}"
(cd "${WS}" && MCPBASH_TMP_ROOT="${root4}" MCPBASH_TOOL_ALLOWLIST="${ALLOW}" exec bash ./bin/mcp-bash <"${in4}" >/dev/null 2>"${TEST_TMPDIR}/kill.err") &
server=$!
exec 7>"${in4}"
printf '%s\n%s\n%s\n' "${INIT}" "${INITIALIZED}" "$(call c1 long-kill)" >&7
wait_tool_started "${KILL_SECS}"
kill -KILL "${server}"
wait "${server}" 2>/dev/null || true
expect_tool_and_state_gone "host SIGKILL" "${KILL_SECS}" "${root4}"
expect_left_gone "host SIGKILL" "${KILL_LEFT_SECS}"
exec 7>&-

# 5) The same, but the parent never reaps the killed server, so it stays a
# zombie (kill -0 still succeeds on it).
root5="${TEST_TMPDIR}/zombie-root"
mkdir -p "${root5}"
in5="${TEST_TMPDIR}/zombie.in"
go5="${TEST_TMPDIR}/zombie.go"
pid5="${TEST_TMPDIR}/zombie.pid"
mkfifo "${in5}"
exec 7<>"${in5}"
(
	cd "${WS}" || exit 1
	MCPBASH_TMP_ROOT="${root5}" MCPBASH_TOOL_ALLOWLIST="${ALLOW}" PIDF="${pid5}" GO="${go5}" exec perl -e '
		my $pid = fork;
		defined $pid or exit 1;
		if (!$pid) { exec @ARGV or exit 127; }
		open(my $f, ">", $ENV{PIDF}) or exit 1; print $f $pid; close $f;
		until (-e $ENV{GO}) { select(undef, undef, undef, 0.1); }
		kill 9, $pid;
		sleep 30;
	' bash ./bin/mcp-bash <"${in5}" >/dev/null 2>"${TEST_TMPDIR}/zombie.err"
) &
zparent=$!
while [ ! -s "${pid5}" ]; do sleep 0.1; done
printf '%s\n%s\n%s\n' "${INIT}" "${INITIALIZED}" "$(call c1 long-zombie)" >&7
wait_tool_started "${ZOMBIE_SECS}"
: >"${go5}"
expect_tool_and_state_gone "SIGKILL, never reaped" "${ZOMBIE_SECS}" "${root5}"
kill "${zparent}" 2>/dev/null || true
exec 7>&-

printf 'exit stops tools test passed.\n'
