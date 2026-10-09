#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Server exits when its stdout reader goes away, even if the host ignores SIGPIPE."
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
printf '%s\n' '{"name": "stdout-closed"}' >"${WS}/server.d/server.meta.json"

LIMIT=10
# The test writes to the server's stdin after the server may have exited.
trap '' PIPE
in_fifo="${TEST_TMPDIR}/in"
out_fifo="${TEST_TMPDIR}/out"
mkfifo "${in_fifo}" "${out_fifo}"

# A host that ignores SIGPIPE (signals ignored at exec stay ignored in bash), so
# writes to a closed stdout fail with EPIPE instead of killing the writer.
(
	trap '' PIPE
	cd "${WS}" && exec bash ./bin/mcp-bash <"${in_fifo}" >"${out_fifo}" 2>"${TEST_TMPDIR}/stderr"
) &
server=$!
exec 7>"${in_fifo}"
exec 8<"${out_fifo}"

printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}' >&7
IFS= read -r -t 10 first <&8 || test_fail "no initialize response"

# The client stops reading but keeps stdin open.
exec 8<&-
# One request whose response cannot be delivered is enough: the client is gone.
printf '%s\n' '{"jsonrpc":"2.0","id":"p1","method":"ping"}' >&7 2>/dev/null || true

waited=0
while kill -0 "${server}" 2>/dev/null; do
	if [ "${waited}" -ge "${LIMIT}" ]; then
		kill -KILL "${server}" 2>/dev/null || true
		exec 7>&-
		test_fail "server still running ${LIMIT}s after its stdout reader closed"
	fi
	sleep 1
	waited=$((waited + 1))
done
exec 7>&-
wait "${server}" 2>/dev/null || true
printf 'Server exited ~%ss after its stdout reader closed.\n' "${waited}"
printf 'stdout closed exit test passed.\n'
