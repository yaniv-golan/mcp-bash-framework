#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="A request split across the read timeout, and a final request without a newline, are each answered once."
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
mkdir -p "${WS}/server.d"
printf '%s\n' '{"name": "split-read"}' >"${WS}/server.d/server.meta.json"

# A client may write one request in several chunks. With the timed read loop
# (real mode, 1s read timeout here) a pause longer than the timeout used to
# drop the first chunk (bash 3.2) or answer it as a separate, broken message
# (bash 4+); either way the request itself was never answered.
exited() { ! kill -0 "$1" 2>/dev/null; }

check() {
	local shell_bin="$1" mode="$2" split="$3"
	local fifo="${TEST_TMPDIR}/in.${RANDOM}" out="${TEST_TMPDIR}/out.${RANDOM}"
	mkfifo "${fifo}"
	(
		cd "${WS}" || exit 1
		if [ "${mode}" = "ci" ]; then
			export MCPBASH_CI_MODE=true
		else
			unset MCPBASH_CI_MODE
		fi
		MCPBASH_ORPHAN_CHECK_INTERVAL=1 exec "${shell_bin}" ./bin/mcp-bash <"${fifo}" >"${out}" 2>/dev/null
	) &
	local pid=$!
	exec 7>"${fifo}"
	if [ "${split}" = "split" ]; then
		printf '%s' '{"jsonrpc":"2.0","id":"init","method":"initi' >&7
		sleep 2.5
		printf '%s\n' 'alize","params":{}}' >&7
	else
		printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}' >&7
	fi
	printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&7
	printf '%s\n' '{"jsonrpc":"2.0","id":"ping1","method":"ping"}' >&7
	# The last request has no trailing newline; closing stdin ends it.
	printf '%s' '{"jsonrpc":"2.0","id":"last","method":"ping"}' >&7
	exec 7>&-
	# The server exits once it has answered everything; the limit only
	# guards against a hang, so it is generous for loaded runners.
	test_wait_until 60 exited "${pid}" || true
	kill -KILL "${pid}" 2>/dev/null || true
	wait "${pid}" 2>/dev/null || true
	rm -f "${fifo}"

	local label="${shell_bin} ${mode} ${split}"
	local id count
	for id in init ping1 last; do
		count="$(jq -s --arg id "${id}" '[.[] | select(.id == $id and has("result"))] | length' "${out}")"
		[ "${count}" = "1" ] || test_fail "${label}: expected one result for ${id}, got ${count}: $(cat "${out}")"
	done
	if jq -e 'select(.error.code == -32700)' "${out}" >/dev/null 2>&1; then
		test_fail "${label}: a fragment was answered as a parse error: $(cat "${out}")"
	fi
	printf '  %s: ok\n' "${label}"
}

shells="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" != "$(bash -c 'echo ${BASH_VERSINFO[0]}')" ]; then
	shells="bash /bin/bash"
fi
for shell_bin in ${shells}; do
	check "${shell_bin}" real split
	check "${shell_bin}" real whole
	check "${shell_bin}" ci whole
done
printf 'Split message read test passed.\n'
