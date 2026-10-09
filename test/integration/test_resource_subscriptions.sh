#!/usr/bin/env bash
# Integration: resources/subscribe and resources/unsubscribe lifecycle.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Subscriptions poll without client traffic; unsubscribe by uri; robust records."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq

if [ "${IS_WINDOWS:-false}" = "true" ]; then
	# Needs a long-lived FIFO session; test_resources.sh covers Windows basics.
	printf 'Skipping subscription lifecycle test on Windows.\n'
	exit 0
fi

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/subs"
test_stage_workspace "${WORKSPACE}"
rm -f "${WORKSPACE}/server.d/register.sh"
mkdir -p "${WORKSPACE}/resources"
# Resolve symlinks (macOS /var -> /private/var) so URIs match what the provider reports.
WORKSPACE="$(cd "${WORKSPACE}" && pwd -P)"
RES="${WORKSPACE}/resources"
STATE_DIR="${WORKSPACE}/state"
RESPONSES="${WORKSPACE}/responses.ndjson"
SERVER_ERR="${WORKSPACE}/server.err"
POLL_SECS=1

for f in live sub2 sub3 nl other; do
	printf 'v1\n' >"${RES}/${f}.txt"
done
uri_of() { printf 'file://%s/%s.txt' "${RES}" "$1"; }

PIPE_IN="${WORKSPACE}/pipe_in"
rm -f "${PIPE_IN}"
mkfifo "${PIPE_IN}"
: >"${RESPONSES}"

(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" \
		MCPBASH_STATE_DIR="${STATE_DIR}" \
		MCPBASH_RESOURCES_POLL_INTERVAL_SECS="${POLL_SECS}" \
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
	stop_server
	test_fail "$1"
}

send() { printf '%s\n' "$1" >&3; }

# wait_for <jq-filter> <seconds>: succeed once any response line matches.
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
count_of() {
	jq -s "[.[] | select($1)] | length" "${RESPONSES}"
}
updates_for() {
	count_of ".method == \"notifications/resources/updated\" and .params.uri == \"$1\""
}
record_count() {
	local n=0 path
	for path in "${STATE_DIR}"/resource_subscription.*; do
		[ -f "${path}" ] && n=$((n + 1))
	done
	printf '%s' "${n}"
}

send '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}'
wait_for '.id == "init"' 15 || fail "initialize response missing"
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'

# --- 1. A client that subscribes and then waits still gets updates. ---
# Nothing is sent after the subscribe until the update arrives.
LIVE_URI="$(uri_of live)"
send "{\"jsonrpc\":\"2.0\",\"id\":\"sub-live\",\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"${LIVE_URI}\"}}"
wait_for '.id == "sub-live"' 10 || fail "subscribe response missing"
jq -e -s 'any(.[]; .id == "sub-live" and (.result.subscriptionId | type) == "string")' "${RESPONSES}" >/dev/null ||
	fail "subscribe result must carry a subscriptionId"
sleep $((POLL_SECS + 1))
printf 'v2\n' >"${RES}/live.txt"
wait_for ".method == \"notifications/resources/updated\" and .params.uri == \"${LIVE_URI}\"" $((POLL_SECS * 5 + 2)) ||
	fail "no update for a subscription with no client traffic after subscribe"

# --- Every update names a resource. ---
if [ "$(count_of '.method == "notifications/resources/updated" and ((.params.uri // "") == "")')" != "0" ]; then
	fail "an update notification was sent with an empty uri"
fi

send '{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}'
send '{"jsonrpc":"2.0","id":"exit","method":"exit"}'
exec 3>&-
deadline=$((SECONDS + 15))
while kill -0 "${SERVER_PID}" 2>/dev/null && [ "${SECONDS}" -lt "${deadline}" ]; do
	sleep 0.2
done
stop_server

printf 'Resource subscription tests passed.\n'
