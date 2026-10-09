#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Server exits promptly on SIGTERM/SIGINT while waiting for input."
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

# mode "real": idle/orphan checks on (timed read). mode "ci": blocking read.
check_signal() {
	local signal="$1" mode="$2" fifo="${TEST_TMPDIR}/in.${RANDOM}"
	mkfifo "${fifo}"
	if [ "${mode}" = "ci" ]; then
		(cd "${WS}" && export MCPBASH_CI_MODE=true && launch bash ./bin/mcp-bash <"${fifo}" >/dev/null 2>&1) &
	else
		(cd "${WS}" && unset MCPBASH_CI_MODE && launch bash ./bin/mcp-bash <"${fifo}" >/dev/null 2>&1) &
	fi
	local pid=$!
	exec 7>"${fifo}"
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}' >&7
	sleep 2
	kill "-${signal}" "${pid}" 2>/dev/null || true
	local waited=0
	while kill -0 "${pid}" 2>/dev/null; do
		if [ "${waited}" -ge "${LIMIT}" ]; then
			kill -KILL "${pid}" 2>/dev/null || true
			exec 7>&-
			rm -f "${fifo}"
			test_fail "${signal} (${mode} mode): server still running ${LIMIT}s after the signal"
		fi
		sleep 1
		waited=$((waited + 1))
	done
	wait "${pid}" 2>/dev/null || true
	exec 7>&-
	rm -f "${fifo}"
	printf '  %s (%s mode): exited after ~%ss\n' "${signal}" "${mode}" "${waited}"
}

for mode in real ci; do
	check_signal TERM "${mode}"
	check_signal INT "${mode}"
done

printf 'Signal exit test passed.\n'
