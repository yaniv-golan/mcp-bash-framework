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

# A provider whose reads take a while, so a subscribe's initial read is still
# running when a following unsubscribe arrives.
SLOW_URI="slow://item"
SLOW_DATA="${WORKSPACE}/slow.data"
printf 'v1\n' >"${SLOW_DATA}"
mkdir -p "${WORKSPACE}/providers"
cat >"${WORKSPACE}/providers/slow.sh" <<EOF
#!/usr/bin/env bash
sleep 2
cat "${SLOW_DATA}"
EOF
chmod +x "${WORKSPACE}/providers/slow.sh"
printf 'placeholder for the slow provider\n' >"${RES}/slow.txt"
cat >"${RES}/slow.meta.json" <<EOF
{"name": "slow-item", "uri": "${SLOW_URI}", "mimeType": "text/plain", "provider": "slow"}
EOF
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
jq -e -s 'any(.[]; .id == "sub-live" and (.result.subscriptionId | type) == "string")' "${RESPONSES}" >/dev/null \
	|| fail "subscribe result must carry a subscriptionId"
sleep $((POLL_SECS + 1))
printf 'v2\n' >"${RES}/live.txt"
wait_for ".method == \"notifications/resources/updated\" and .params.uri == \"${LIVE_URI}\"" $((POLL_SECS * 5 + 2)) \
	|| fail "no update for a subscription with no client traffic after subscribe"

# --- 2. Unsubscribe by uri (MCP UnsubscribeRequest params are {uri}). ---
SUB2_URI="$(uri_of sub2)"
send "{\"jsonrpc\":\"2.0\",\"id\":\"sub2a\",\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"${SUB2_URI}\"}}"
send "{\"jsonrpc\":\"2.0\",\"id\":\"sub2b\",\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"${SUB2_URI}\"}}"
wait_for '.id == "sub2a"' 10 || fail "subscribe sub2a missing"
wait_for '.id == "sub2b"' 10 || fail "subscribe sub2b missing"
records_before="$(record_count)"
send "{\"jsonrpc\":\"2.0\",\"id\":\"unsub2\",\"method\":\"resources/unsubscribe\",\"params\":{\"uri\":\"${SUB2_URI}\"}}"
wait_for '.id == "unsub2"' 10 || fail "unsubscribe by uri: no response"
jq -e -s 'any(.[]; .id == "unsub2" and .result == {})' "${RESPONSES}" >/dev/null \
	|| fail "unsubscribe by uri must return an empty result"
records_after="$(record_count)"
if [ "$((records_before - records_after))" -ne 2 ]; then
	fail "unsubscribe by uri must remove both subscriptions to that uri (before=${records_before} after=${records_after})"
fi
sub2_updates_before="$(updates_for "${SUB2_URI}")"
printf 'v2\n' >"${RES}/sub2.txt"
sleep $((POLL_SECS * 3 + 1))
if [ "$(updates_for "${SUB2_URI}")" != "${sub2_updates_before}" ]; then
	fail "update sent for a uri after unsubscribe by uri"
fi

# Unsubscribing a uri with no subscription is a successful no-op.
send "{\"jsonrpc\":\"2.0\",\"id\":\"unsub-unknown\",\"method\":\"resources/unsubscribe\",\"params\":{\"uri\":\"$(uri_of nowhere)\"}}"
wait_for '.id == "unsub-unknown"' 10 || fail "unsubscribe unknown uri: no response"
jq -e -s 'any(.[]; .id == "unsub-unknown" and .result == {})' "${RESPONSES}" >/dev/null \
	|| fail "unsubscribe of an unknown uri must return an empty result"
# Neither uri nor subscriptionId: invalid params.
send '{"jsonrpc":"2.0","id":"unsub-empty","method":"resources/unsubscribe","params":{}}'
wait_for '.id == "unsub-empty"' 10 || fail "unsubscribe without params: no response"
jq -e -s 'any(.[]; .id == "unsub-empty" and .error.code == -32602)' "${RESPONSES}" >/dev/null \
	|| fail "unsubscribe without uri or subscriptionId must return -32602"

# Legacy: unsubscribe by the subscriptionId that subscribe returned still works.
SUB3_URI="$(uri_of sub3)"
send "{\"jsonrpc\":\"2.0\",\"id\":\"sub3\",\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"${SUB3_URI}\"}}"
wait_for '.id == "sub3"' 10 || fail "subscribe sub3 missing"
sub3_id="$(jq -r -s '.[] | select(.id == "sub3") | .result.subscriptionId' "${RESPONSES}")"
records_before="$(record_count)"
send "{\"jsonrpc\":\"2.0\",\"id\":\"unsub3\",\"method\":\"resources/unsubscribe\",\"params\":{\"subscriptionId\":\"${sub3_id}\"}}"
wait_for '.id == "unsub3"' 10 || fail "unsubscribe by subscriptionId: no response"
jq -e -s 'any(.[]; .id == "unsub3" and .result == {})' "${RESPONSES}" >/dev/null \
	|| fail "unsubscribe by subscriptionId must return an empty result"
if [ "$((records_before - $(record_count)))" -ne 1 ]; then
	fail "unsubscribe by subscriptionId must remove that subscription"
fi

# --- 3. A newline in the name or uri cannot redirect a subscription. ---
NL_URI="$(uri_of nl)"
OTHER_URI="$(uri_of other)"
send "{\"jsonrpc\":\"2.0\",\"id\":\"sub-nl\",\"method\":\"resources/subscribe\",\"params\":{\"name\":\"bogus\\n${OTHER_URI}\",\"uri\":\"${NL_URI}\"}}"
wait_for '.id == "sub-nl"' 10 || fail "subscribe with newline name: no response"
if jq -e -s 'any(.[]; .id == "sub-nl" and has("result"))' "${RESPONSES}" >/dev/null; then
	sleep $((POLL_SECS * 2 + 1))
	printf 'v2\n' >"${RES}/other.txt"
	printf 'v2\n' >"${RES}/nl.txt"
	wait_for ".method == \"notifications/resources/updated\" and .params.uri == \"${NL_URI}\"" $((POLL_SECS * 5 + 2)) \
		|| fail "subscription with a newline in its name did not track its uri"
	if [ "$(updates_for "${OTHER_URI}")" != "0" ]; then
		fail "a newline in the subscribe name redirected the subscription to another uri"
	fi
fi

# --- 4. An unsubscribe sent right after a subscribe wins. ---
# Requests run in parallel workers, so the unsubscribe finishes while the
# subscribe's initial read is still running. The subscription must still end
# up removed: no record is left and no update is sent.
send "{\"jsonrpc\":\"2.0\",\"id\":\"sub-race\",\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"${SLOW_URI}\"}}"
send "{\"jsonrpc\":\"2.0\",\"id\":\"unsub-race\",\"method\":\"resources/unsubscribe\",\"params\":{\"uri\":\"${SLOW_URI}\"}}"
wait_for '.id == "unsub-race"' 10 || fail "unsubscribe after subscribe: no response"
wait_for '.id == "sub-race"' 15 || fail "subscribe before unsubscribe: no response"
jq -e -s 'any(.[]; .id == "sub-race" and has("result"))' "${RESPONSES}" >/dev/null \
	|| fail "subscribe before unsubscribe must still succeed"
slow_records="$(cat "${STATE_DIR}"/resource_subscription.* 2>/dev/null | jq -s --arg u "${SLOW_URI}" '[.[] | select(.uri == $u or .requested_uri == $u)] | length')"
if [ "${slow_records}" != "0" ]; then
	fail "a subscribe overtaken by its unsubscribe left ${slow_records} live subscription(s)"
fi
printf 'v2\n' >"${SLOW_DATA}"
sleep $((POLL_SECS * 3 + 4))
if [ "$(updates_for "${SLOW_URI}")" != "0" ]; then
	fail "update sent for a subscription that was unsubscribed right after subscribing"
fi

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
