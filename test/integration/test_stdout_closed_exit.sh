#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Server exits when its stdout reader goes away, whether the host ignores SIGPIPE or not, and when only a tool worker writes."
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
mkdir -p "${WS}/tools/slow"
printf '%s\n' '{"name": "slow", "description": "Answers after 2s", "inputSchema": {"type": "object", "properties": {}}, "timeoutSecs": 20}' >"${WS}/tools/slow/tool.meta.json"
printf '#!/usr/bin/env bash\nsleep 2\nprintf done\n' >"${WS}/tools/slow/tool.sh"
chmod +x "${WS}/tools/slow/tool.sh"

# The test writes to the server's stdin after the server may have exited.
trap '' PIPE

# $1: label; $2: "main" (a ping answered by the main shell) or "worker" (only a
# tool worker writes after the client stops reading); $3: "ignore" (the host
# ignores SIGPIPE, so writes fail with EPIPE) or "default" (SIGPIPE would kill
# the writer).
run_case() {
	local label="$1" writer="$2" sigpipe="$3"
	local in_fifo="${TEST_TMPDIR}/${label}.in" out_fifo="${TEST_TMPDIR}/${label}.out"
	local err="${TEST_TMPDIR}/${label}.stderr"
	mkfifo "${in_fifo}" "${out_fifo}"

	# Signals ignored at exec stay ignored in bash, so "ignore" models a host
	# that ignores SIGPIPE.
	(
		if [ "${sigpipe}" = "ignore" ]; then
			trap '' PIPE
		else
			trap - PIPE
		fi
		cd "${WS}" && MCPBASH_TOOL_ALLOWLIST='slow' exec bash ./bin/mcp-bash <"${in_fifo}" >"${out_fifo}" 2>"${err}"
	) &
	local server=$!
	exec 7>"${in_fifo}"
	exec 8<"${out_fifo}"

	local line=""
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}' >&7
	# Generous: only a loaded runner takes more than a second.
	IFS= read -r -t 60 line <&8 || test_fail "${label}: no initialize response"

	if [ "${writer}" = "main" ]; then
		# The client stops reading but keeps stdin open. One request whose
		# response cannot be delivered is enough: the client is gone.
		exec 8<&-
		printf '%s\n' '{"jsonrpc":"2.0","id":"p1","method":"ping"}' >&7 2>/dev/null || true
	else
		printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&7
		# Read until tools/list answers, so nothing the main shell sends is
		# still pending when the client stops reading.
		printf '%s\n' '{"jsonrpc":"2.0","id":"tl","method":"tools/list","params":{}}' >&7
		while IFS= read -r -t 60 line <&8; do
			case "${line}" in *'"id":"tl"'*) break ;; esac
		done
		printf '%s\n' '{"jsonrpc":"2.0","id":"c1","method":"tools/call","params":{"name":"slow","arguments":{}}}' >&7
		sleep 1
		while IFS= read -r -t 1 line <&8; do :; done
		# Stop reading while the tool runs; send nothing else.
		exec 8<&-
	fi

	local waited=0
	while kill -0 "${server}" 2>/dev/null; do
		if [ "${waited}" -ge "${LIMIT}" ]; then
			kill -KILL "${server}" 2>/dev/null || true
			exec 7>&-
			cat "${err}" >&2
			test_fail "${label}: server still running ${LIMIT}s after its stdout reader closed"
		fi
		sleep 1
		waited=$((waited + 1))
	done
	exec 7>&-
	wait "${server}" 2>/dev/null || true
	if ! grep -q 'the client stopped reading, shutting down' "${err}"; then
		cat "${err}" >&2
		test_fail "${label}: server exited without reporting the closed stdout"
	fi
	printf ' -> %s: server exited ~%ss after its stdout reader closed\n' "${label}" "${waited}"
}

for sigpipe in ignore default; do
	run_case "main-shell-${sigpipe}" main "${sigpipe}"
	run_case "tool-worker-${sigpipe}" worker "${sigpipe}"
done
printf 'stdout closed exit test passed.\n'
