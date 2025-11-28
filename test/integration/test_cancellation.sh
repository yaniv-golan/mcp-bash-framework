#!/usr/bin/env bash
# Integration: cancellation notification terminates a running worker.

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

mkdir -p "${WORKSPACE}/tools"
cat <<'META' >"${WORKSPACE}/tools/slow.meta.json"
{"name":"cancel.slow","description":"slow","arguments":{"type":"object","properties":{}}}
META
cat <<'SH' >"${WORKSPACE}/tools/slow.sh"
#!/usr/bin/env bash
sleep 10
echo "done"
SH
chmod +x "${WORKSPACE}/tools/slow.sh"

PIPE_IN="${WORKSPACE}/in"
PIPE_OUT="${WORKSPACE}/out"
rm -f "${PIPE_IN}" "${PIPE_OUT}"
mkfifo "${PIPE_IN}" "${PIPE_OUT}"

(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" ./bin/mcp-bash <"${PIPE_IN}" >"${PIPE_OUT}" &
	echo $! >"${WORKSPACE}/server.pid"
) || exit 1

exec 3>"${PIPE_IN}"
exec 4<"${PIPE_OUT}"

send() { printf '%s\n' "$1" >&3; }
read_resp() {
	local line
	read -r -t 2 -u 4 line && printf '%s' "${line}"
}

send '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}'
read_resp >/dev/null || true
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'

send '{"jsonrpc":"2.0","id":"slow","method":"tools/call","params":{"name":"cancel.slow","arguments":{}}}'
sleep 1
send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"id":"slow"}}'

# Ping to flush events
send '{"jsonrpc":"2.0","id":"ping","method":"ping"}'

got_call=false
got_ping=false
deadline=$((SECONDS + 15))
while [ "${SECONDS}" -lt "${deadline}" ]; do
	line="$(read_resp || true)"
	[ -z "${line}" ] && continue
	id="$(printf '%s' "${line}" | jq -r '.id // empty')"
	if [ "${id}" = "slow" ]; then
		got_call=true
	fi
	if [ "${id}" = "ping" ]; then
		got_ping=true
	fi
	# If ping hasn’t arrived after a few seconds, send another probe.
	if [ "${got_ping}" != true ] && [ $((deadline - SECONDS)) -le 10 ]; then
		send '{"jsonrpc":"2.0","id":"ping2","method":"ping"}'
	fi
	if [ "${got_ping}" = true ]; then
		break
	fi
done

if [ "${got_call}" = true ]; then
	test_fail "slow call should be cancelled without result"
fi
if [ "${got_ping}" != true ]; then
	test_fail "ping response missing after cancellation"
fi

send '{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}'
send '{"jsonrpc":"2.0","id":"exit","method":"exit"}'
exec 3>&-
while read -t 2 -r -u 4 _line; do :; done
exec 4<&-
if [ -f "${WORKSPACE}/server.pid" ]; then
	wait "$(cat "${WORKSPACE}/server.pid")" 2>/dev/null || true
fi

printf 'Cancellation tests passed.\n'
