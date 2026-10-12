#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Warnings logged while the subscription poller rescans never corrupt its reads."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq

case "$(uname -s 2>/dev/null)" in
CYGWIN* | MINGW* | MSYS*)
	printf 'SKIP: subscription polling test needs a FIFO\n'
	exit 0
	;;
esac

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/poller"
test_stage_workspace "${WORKSPACE}"
rm -f "${WORKSPACE}/server.d/register.sh" "${WORKSPACE}/providers/"*.sh
rm -rf "${WORKSPACE}/resources"
mkdir -p "${WORKSPACE}/resources"
WORKSPACE="$(cd "${WORKSPACE}" && pwd -P)"
RES="${WORKSPACE}/resources"
RESPONSES="${WORKSPACE}/responses.ndjson"
SERVER_ERR="${WORKSPACE}/server.err"

printf 'v1\n' >"${RES}/live.txt"
LIVE_URI="file://${RES}/live.txt"
# A custom-scheme resource with no provider script: every rescan of the
# resources registry logs a warning for it.
printf 'x\n' >"${RES}/orphan.txt"
printf '%s\n' '{"name": "orphan", "uri": "noscript://orphan"}' >"${RES}/orphan.meta.json"

PIPE_IN="${WORKSPACE}/pipe_in"
mkfifo "${PIPE_IN}"
: >"${RESPONSES}"
(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" \
		MCPBASH_RESOURCES_POLL_INTERVAL_SECS=1 \
		MCP_RESOURCES_TTL=0 \
		./bin/mcp-bash <"${PIPE_IN}" >"${RESPONSES}" 2>"${SERVER_ERR}" &
	echo $! >"${WORKSPACE}/server.pid"
) || exit 1
exec 3>"${PIPE_IN}"
SERVER_PID="$(cat "${WORKSPACE}/server.pid")"

stop_server() {
	{ exec 3>&-; } 2>/dev/null || true
	if kill -0 "${SERVER_PID}" 2>/dev/null; then
		kill "${SERVER_PID}" 2>/dev/null || true
	fi
}
fail() {
	printf '%s\n' '--- responses ---' >&2
	cat "${RESPONSES}" >&2 || true
	printf '%s\n' '--- server stderr ---' >&2
	cat "${SERVER_ERR}" >&2 || true
	stop_server
	test_fail "$1"
}
send() { printf '%s\n' "$1" >&3; }
wait_for() {
	local filter="$1" secs="$2"
	local deadline=$((SECONDS + secs))
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		if jq -e -s "any(.[]; ${filter})" "${RESPONSES}" >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.2
	done
	return 1
}

send '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}'
wait_for '.id == "init"' 15 || fail "initialize response missing"
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
send "{\"jsonrpc\":\"2.0\",\"id\":\"sub\",\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"${LIVE_URI}\"}}"
wait_for '.id == "sub"' 10 || fail "subscribe response missing"

# Force rebuilds while the poller reads: a changed meta file changes the
# registry, so the next refresh rebuilds it and logs the warning again.
for n in 1 2 3 4; do
	sleep 1
	printf '{"name": "orphan", "uri": "noscript://orphan", "description": "v%s"}\n' "${n}" >"${RES}/orphan.meta.json"
done
printf 'v2\n' >"${RES}/live.txt"
printf '%s\n' '{"name": "orphan", "uri": "noscript://orphan", "description": "v5"}' >"${RES}/orphan.meta.json"
wait_for ".method == \"notifications/resources/updated\" and .params.uri == \"${LIVE_URI}\"" 15 \
	|| fail "no resources/updated after the change"
sleep 2
stop_server

# Every line on stdout is a JSON-RPC message.
if ! jq -e -s 'all(.[]; type == "object" and .jsonrpc == "2.0")' "${RESPONSES}" >/dev/null 2>&1; then
	fail "stdout has lines that are not JSON-RPC messages"
fi
if grep -E 'jq: error|invalid JSON text|integer expression expected|parse error' "${SERVER_ERR}" >/dev/null 2>&1; then
	fail "server stderr shows corrupted registry data"
fi
if jq -e -s "any(.[]; .method == \"notifications/message\" and .params.level == \"error\" and (.params.data | tostring | test(\"live\")))" "${RESPONSES}" >/dev/null 2>&1; then
	fail "the poller reported an error reading ${LIVE_URI}"
fi
printf ' -> poller reads intact while rescans log warnings\n'
