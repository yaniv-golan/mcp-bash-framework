#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Background helper loops exit when the server dies without cleanup."
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
printf '%s\n' '{"name": "bg-loops"}' >"${WS}/server.d/server.meta.json"

fifo="${TEST_TMPDIR}/in"
mkfifo "${fifo}"
(cd "${WS}" && exec bash ./bin/mcp-bash <"${fifo}" >/dev/null 2>&1) &
server=$!
exec 7>"${fifo}"
# Declaring elicitation support makes the server start its progress/elicitation
# flusher, a background loop.
printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"elicitation":{}}}}' >&7
printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&7

# Wait for the server's background helpers (progress flusher etc.) to start.
children=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
	children="$(pgrep -P "${server}" 2>/dev/null | tr '\n' ' ' || true)"
	[ -n "${children}" ] && break
	sleep 0.5
done
[ -n "${children}" ] || test_fail "server started no background helpers to check"

# Kill the server without giving it a chance to clean up.
kill -KILL "${server}" 2>/dev/null || true
wait "${server}" 2>/dev/null || true
exec 7>&-

leftover=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
	leftover=""
	for pid in ${children}; do
		kill -0 "${pid}" 2>/dev/null && leftover="${leftover} ${pid}"
	done
	[ -z "${leftover}" ] && break
	sleep 0.5
done
if [ -n "${leftover}" ]; then
	for pid in ${leftover}; do kill -KILL "${pid}" 2>/dev/null || true; done
	test_fail "background helpers outlived the server by 5s:${leftover}"
fi

printf 'Background loops exit test passed.\n'
