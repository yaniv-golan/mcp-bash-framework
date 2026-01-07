#!/usr/bin/env bash
# Stress: fan out many parallel tool calls and ensure they succeed without deadlock.

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
WORKSPACE="${TEST_TMPDIR}/concurrency"
test_stage_workspace "${WORKSPACE}"

# Install a simple tool
mkdir -p "${WORKSPACE}/tools/echo"
cat <<'META' >"${WORKSPACE}/tools/echo/tool.meta.json"
{"name": "stress.echo", "description": "Echo args", "arguments": {"type": "object", "properties": {"msg": {"type": "string"}}}}
META
cat <<'SH' >"${WORKSPACE}/tools/echo/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$("${MCPBASH_JSON_TOOL_BIN}" -r '.msg // "ok"' <<<"${MCP_TOOL_ARGS_JSON:-"{}"}")"
SH
chmod +x "${WORKSPACE}/tools/echo/tool.sh"

# Launch server
PIPE_IN="${WORKSPACE}/pipe_in"
PIPE_OUT="${WORKSPACE}/pipe_out"
rm -f "${PIPE_IN}" "${PIPE_OUT}"
mkfifo "${PIPE_IN}" "${PIPE_OUT}"
(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" MCPBASH_SHUTDOWN_TIMEOUT=10 ./bin/mcp-bash <"${PIPE_IN}" >"${PIPE_OUT}" &
	echo $! >"${WORKSPACE}/server.pid"
) || exit 1

exec 3>"${PIPE_IN}"
exec 4<"${PIPE_OUT}"

send() { printf '%s\n' "$1" >&3; }
read_resp() {
	local line
	read -r -u 4 line && printf '%s' "${line}"
}

send '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}'
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
send '{"jsonrpc":"2.0","id":"list","method":"tools/list"}'
read_resp >/dev/null || true
read_resp >/dev/null || true
read_resp >/dev/null || true

PARALLEL=20
for i in $(seq 1 "${PARALLEL}"); do
	send "$(jq -nc --arg id "call-$i" --arg msg "hi-$i" '{jsonrpc:"2.0",id:$id,method:"tools/call",params:{name:"stress.echo",arguments:{msg:$msg}}}')"
done

deadline=$((SECONDS + 20))
received=0
while [ "${received}" -lt "${PARALLEL}" ] && [ "${SECONDS}" -lt "${deadline}" ]; do
	line="$(read_resp || true)"
	[ -z "${line}" ] && continue
	id="$(printf '%s' "${line}" | jq -r '.id // empty')"
	if [[ "${id}" == call-* ]]; then
		if ! printf '%s' "${line}" | jq -e '.result.content[0].text | startswith("hi-")' >/dev/null; then
			echo "Bad response: ${line}" >&2
			exit 1
		fi
		received=$((received + 1))
	fi
done

if [ "${received}" -lt "${PARALLEL}" ]; then
	echo "Only ${received}/${PARALLEL} responses received" >&2
	exit 1
fi

send '{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}'
send '{"jsonrpc":"2.0","id":"exit","method":"exit"}'

exec 3>&-
exec 4<&-

if [ -f "${WORKSPACE}/server.pid" ]; then
	server_pid="$(cat "${WORKSPACE}/server.pid")"
	wait_deadline=$((SECONDS + 10))
	while kill -0 "${server_pid}" 2>/dev/null && [ "${SECONDS}" -lt "${wait_deadline}" ]; do
		sleep 1
	done
	kill "${server_pid}" 2>/dev/null || true
	wait "${server_pid}" 2>/dev/null || true
fi

echo "Concurrency stress passed."
