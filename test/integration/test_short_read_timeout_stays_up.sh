#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Short read timeouts (orphan interval 1s) do not look like EOF to the server."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir
unset MCPBASH_CI_MODE

WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
mkdir -p "${WS}/server.d"
printf '%s\n' '{"name": "short-timeout"}' >"${WS}/server.d/server.meta.json"

STAY=10
check_shell() {
	local shell_bin="$1" fifo="${TEST_TMPDIR}/in.${RANDOM}"
	mkfifo "${fifo}"
	(cd "${WS}" && MCPBASH_ORPHAN_CHECK_INTERVAL=1 exec "${shell_bin}" ./bin/mcp-bash <"${fifo}" >/dev/null 2>&1) &
	local pid=$!
	exec 7>"${fifo}"
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}' >&7
	# Client stays connected (stdin open) but idle.
	sleep "${STAY}"
	if ! kill -0 "${pid}" 2>/dev/null; then
		exec 7>&-
		rm -f "${fifo}"
		test_fail "${shell_bin}: server exited while the client was still connected (1s read timeouts mistaken for EOF)"
	fi
	exec 7>&-
	local waited=0
	while kill -0 "${pid}" 2>/dev/null && [ "${waited}" -lt 10 ]; do
		sleep 1
		waited=$((waited + 1))
	done
	kill -KILL "${pid}" 2>/dev/null || true
	wait "${pid}" 2>/dev/null || true
	rm -f "${fifo}"
	printf '  %s: stayed up %ss while connected; exited ~%ss after stdin closed\n' "${shell_bin}" "${STAY}" "${waited}"
}

shells="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" != "$(bash -c 'echo ${BASH_VERSINFO[0]}')" ]; then
	shells="bash /bin/bash"
fi
for shell_bin in ${shells}; do
	check_shell "${shell_bin}"
done
printf 'Short read timeout test passed.\n'
