#!/usr/bin/env bash
# Integration: cancellation notification terminates a running worker.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Cancellation request aborts a running worker."

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
WORKSPACE="${TEST_TMPDIR}/cancel"
test_stage_workspace "${WORKSPACE}"

# The tool runs for TOOL_SECS. A cancelled call must stay silent well past that,
# so the test keeps reading for at least TOOL_SECS + GRACE_SECS after the calls
# start, and GRACE_SECS after an uncancelled control call returns.
TOOL_SECS=3
GRACE_SECS=4

mkdir -p "${WORKSPACE}/tools/slow"
cat <<'META' >"${WORKSPACE}/tools/slow/tool.meta.json"
{"name":"cancel.slow","description":"slow","arguments":{"type":"object","properties":{}}}
META
cat <<SH >"${WORKSPACE}/tools/slow/tool.sh"
#!/usr/bin/env bash
sleep ${TOOL_SECS}
echo "done"
SH
chmod +x "${WORKSPACE}/tools/slow/tool.sh"

# Use a temp dir for pipes; some runners dislike mkfifo directly under /tmp.
FIFO_ROOT="${WORKSPACE}/pipes"
mkdir -p "${FIFO_ROOT}"
PIPE_IN="${FIFO_ROOT}/in"
PIPE_OUT="${FIFO_ROOT}/out"
rm -f "${PIPE_IN}" "${PIPE_OUT}"
mkfifo "${PIPE_IN}" "${PIPE_OUT}"

(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_SKIP_PROCESS_GROUP_LOOKUP=1 MCPBASH_PROJECT_ROOT="${WORKSPACE}" ./bin/mcp-bash <"${PIPE_IN}" >"${PIPE_OUT}" &
	echo $! >"${WORKSPACE}/server.pid"
) || exit 1

exec 3>"${PIPE_IN}"
exec 4<"${PIPE_OUT}"

send() { printf '%s\n' "$1" >&3; }
read_resp() {
	local line
	read -r -t 1 -u 4 line && printf '%s' "${line}"
}

send '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}'
init_deadline=$((SECONDS + 10))
while [ "${SECONDS}" -lt "${init_deadline}" ]; do
	line="$(read_resp || true)"
	[ -z "${line}" ] && continue
	if [ "$(printf '%s' "${line}" | jq -c '.id' 2>/dev/null || true)" = '"init"' ]; then
		break
	fi
done
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'

call() {
	send "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"tools/call\",\"params\":{\"name\":\"cancel.slow\",\"arguments\":{}}}"
}

# Three calls are cancelled, covering both id types the spec allows (string and
# number) and the legacy params.id field. The "keep" call is never cancelled; its
# result proves the read window below is long enough to observe a late result.
calls_started=${SECONDS}
call '"slow"'
call '7'
call '"legacy"'
call '"keep"'
sleep 1
send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"slow"}}'
send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}'
send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"id":"legacy"}}'

# Read until the uncancelled call answers (a cold start can delay all four
# calls), then keep reading for GRACE_SECS more: the cancelled calls started at
# the same moment, so an uncancelled one would have answered by then too.
seen_ids=""
keep_seen=false
deadline=$((calls_started + 30))
while [ "${SECONDS}" -lt "${deadline}" ]; do
	line="$(read_resp || true)"
	[ -z "${line}" ] && continue
	id="$(printf '%s' "${line}" | jq -c 'if type == "object" and has("id") then .id else empty end' 2>/dev/null || true)"
	[ -z "${id}" ] && continue
	seen_ids="${seen_ids} ${id}"
	if [ "${id}" = '"keep"' ] && [ "${keep_seen}" != true ]; then
		keep_seen=true
		deadline=$((SECONDS + GRACE_SECS))
	fi
done

if [ "${keep_seen}" != true ]; then
	test_fail "uncancelled call produced no result within 30s (seen:${seen_ids:- none})"
fi
if [ $((SECONDS - calls_started)) -lt $((TOOL_SECS + GRACE_SECS)) ]; then
	test_fail "read window ended before the tool's runtime plus grace had passed"
fi
for cancelled in '"slow"' '7' '"legacy"'; do
	case " ${seen_ids} " in
	*" ${cancelled} "*) test_fail "cancelled call id=${cancelled} returned a response (seen:${seen_ids})" ;;
	esac
done

# The server must still answer after the cancellations.
send '{"jsonrpc":"2.0","id":"ping","method":"ping"}'
got_ping=false
ping_deadline=$((SECONDS + 10))
while [ "${SECONDS}" -lt "${ping_deadline}" ]; do
	line="$(read_resp || true)"
	[ -z "${line}" ] && continue
	if [ "$(printf '%s' "${line}" | jq -c '.id' 2>/dev/null || true)" = '"ping"' ]; then
		got_ping=true
		break
	fi
done
if [ "${got_ping}" != true ]; then
	test_fail "ping response missing after cancellation"
fi

send '{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}'
send '{"jsonrpc":"2.0","id":"exit","method":"exit"}'
exec 3>&-
while read -t 2 -r -u 4 _line; do :; done
exec 4<&-
if [ -f "${WORKSPACE}/server.pid" ]; then
	server_pid="$(cat "${WORKSPACE}/server.pid")"
	wait_deadline=$((SECONDS + 30))
	while kill -0 "${server_pid}" 2>/dev/null && [ "${SECONDS}" -lt "${wait_deadline}" ]; do
		sleep 1
	done
	# Ensure no stray server remains; best-effort cleanup on CI.
	if kill -0 "${server_pid}" 2>/dev/null; then
		kill "${server_pid}" 2>/dev/null || true
		wait "${server_pid}" 2>/dev/null || true
	fi
fi

printf 'Cancellation tests passed.\n'
