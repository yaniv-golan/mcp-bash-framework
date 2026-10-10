#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Server exits promptly, with 128+signal and its state removed, on TERM/INT/HUP."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
mkdir -p "${WS}/server.d"
printf '%s\n' '{"name": "sigterm"}' >"${WS}/server.d/server.meta.json"

# A tool that outlives stdin, for the "signal while waiting for workers" case.
mkdir -p "${WS}/tools/slow"
cat >"${WS}/tools/slow/tool.sh" <<'EOF_TOOL'
#!/usr/bin/env bash
sleep 30
printf '{"content":[{"type":"text","text":"done"}]}\n'
EOF_TOOL
chmod +x "${WS}/tools/slow/tool.sh"
printf '%s\n' '{"name":"slow","description":"sleeps","inputSchema":{"type":"object"}}' >"${WS}/tools/slow/tool.meta.json"

# State directories go under a private root so the test can check cleanup.
# CI mode keeps logs (and so the state directory) unless told otherwise.
TMP_ROOT="${TEST_TMPDIR}/tmproot"
mkdir -p "${TMP_ROOT}"
export MCPBASH_TMP_ROOT="${TMP_ROOT}"
export MCPBASH_KEEP_LOGS=false
unset MCPBASH_PRESERVE_STATE MCPBASH_LOG_DIR
export MCPBASH_TOOL_ALLOWLIST=slow

LIMIT=5

# Without job control, bash starts background jobs with SIGINT ignored, and a
# non-interactive shell cannot trap a signal ignored at startup. Real hosts
# (Node, terminals) don't launch servers that way. "set -m" here is not enough:
# the integration runner itself backgrounds this script without job control,
# so SIGINT is already ignored when it starts and every child inherits that.
# Launch the server through perl, which resets SIGINT to the default first.
test_require_command perl
launch() {
	# shellcheck disable=SC2016  # $SIG and @ARGV are perl, not shell.
	exec perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die "exec: $!\n"' "$@"
}

state_dirs() {
	find "${TMP_ROOT}" -maxdepth 1 -name 'mcpbash.state.*' 2>/dev/null
}

# mode "real": idle/orphan checks on (timed read). mode "ci": blocking read.
# phase "idle": signal while the read loop waits for input.
# phase "draining": stdin closed, signal while waiting for a running tool.
check_signal() {
	local signal="$1" mode="$2" expected="$3" phase="${4:-idle}" fifo="${TEST_TMPDIR}/in.${RANDOM}"
	mkfifo "${fifo}"
	if [ "${mode}" = "ci" ]; then
		(cd "${WS}" && export MCPBASH_CI_MODE=true && launch bash ./bin/mcp-bash <"${fifo}" >/dev/null 2>&1) &
	else
		(cd "${WS}" && unset MCPBASH_CI_MODE && launch bash ./bin/mcp-bash <"${fifo}" >/dev/null 2>&1) &
	fi
	local pid=$!
	exec 7>"${fifo}"
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}' >&7
	if [ "${phase}" = "draining" ]; then
		printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&7
		printf '%s\n' '{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"slow","arguments":{}}}' >&7
		sleep 2
		exec 7>&-
	fi
	sleep 2
	if [ -z "$(state_dirs)" ]; then
		kill -KILL "${pid}" 2>/dev/null || true
		test_fail "${signal} (${mode}, ${phase}): no state directory before the signal"
	fi
	kill "-${signal}" "${pid}" 2>/dev/null || true
	local waited=0
	while kill -0 "${pid}" 2>/dev/null; do
		if [ "${waited}" -ge "${LIMIT}" ]; then
			kill -KILL "${pid}" 2>/dev/null || true
			{ exec 7>&-; } 2>/dev/null || true
			rm -f "${fifo}"
			test_fail "${signal} (${mode}, ${phase}): server still running ${LIMIT}s after the signal"
		fi
		sleep 1
		waited=$((waited + 1))
	done
	local status=0
	wait "${pid}" 2>/dev/null || status=$?
	{ exec 7>&-; } 2>/dev/null || true
	rm -f "${fifo}"
	assert_eq "${expected}" "${status}" "${signal} (${mode}, ${phase}): exit status"
	local left
	left="$(state_dirs)"
	if [ -n "${left}" ]; then
		test_fail "${signal} (${mode}, ${phase}): state directory left behind: ${left}"
	fi
	printf '  %s (%s, %s): exited %s after ~%ss, state removed\n' "${signal}" "${mode}" "${phase}" "${status}" "${waited}"
}

for mode in real ci; do
	check_signal TERM "${mode}" 143
	check_signal INT "${mode}" 130
	check_signal HUP "${mode}" 129
	check_signal TERM "${mode}" 143 draining
done

printf 'Signal exit test passed.\n'
