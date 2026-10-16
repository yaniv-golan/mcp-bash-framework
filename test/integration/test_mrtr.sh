#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Modern tools/call questions: input_required, the retry with inputResponses, mcp_once replay, ticket checks."
set -euo pipefail

# It drives the server through named pipes (mkfifo), which Git Bash doesn't
# provide.
case "$(uname -s 2>/dev/null)" in
MINGW* | MSYS* | CYGWIN*)
	printf 'Skipping MRTR test on Windows environment (no mkfifo)\n'
	exit 0
	;;
esac

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
printf '%s\n' '{"name": "mrtr"}' >"${WS}/server.d/server.meta.json"
COUNTS="${TEST_TMPDIR}/counts"
mkdir -p "${COUNTS}"

# add_tool NAME TIMEOUT BODY: TIMEOUT "" for none.
add_tool() {
	local name="$1" timeout="$2" body="$3"
	mkdir -p "${WS}/tools/${name}"
	if [ -n "${timeout}" ]; then
		printf '{"name":"%s","description":"t","inputSchema":{"type":"object"},"timeoutSecs":%s}\n' "${name}" "${timeout}" >"${WS}/tools/${name}/tool.meta.json"
	else
		printf '{"name":"%s","description":"t","inputSchema":{"type":"object"}}\n' "${name}" >"${WS}/tools/${name}/tool.meta.json"
	fi
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		# shellcheck disable=SC2016
		printf 'source "${MCP_SDK}/tool-sdk.sh"\nC="%s"\n' "${COUNTS}"
		# shellcheck disable=SC2016
		printf 'bump() { printf x >>"${C}/$1"; printf "%%s" "$1"; }\n'
		printf '%s\n' "${body}"
	} >"${WS}/tools/${name}/tool.sh"
	chmod +x "${WS}/tools/${name}/tool.sh"
}
# One unwrapped side effect, one wrapped, a question, then a step after it.
# shellcheck disable=SC2016
add_tool deploy 60 '
bump unwrapped >/dev/null
v="$(mcp_once bump wrapped)"
if mcp_elicit_confirm "Deploy ${v}?"; then
	bump after >/dev/null
	echo "deployed"
else
	echo "not deployed: ${MCP_ELICIT_ACTION} (attempt ${MCP_MRTR_ATTEMPT:-none})"
fi'
# Asks after a while, so a cancel can land before the question.
add_tool slowask 60 'sleep 3; mcp_elicit_confirm "Late?" && echo yes || echo no'
add_tool notimeout "" 'if mcp_elicit_confirm "Go?"; then echo go; else echo "no: ${MCP_ELICIT_ACTION}"; fi'
# A question whose text changes on the retry: the run takes another path.
# shellcheck disable=SC2016
add_tool drift 60 'mcp_elicit_confirm "Question for attempt ${MCP_MRTR_ATTEMPT}" && echo yes || echo no'
# shellcheck disable=SC2016
add_tool byarg 60 'mcp_elicit_string -v n --arg name "Name?" && echo "name=${n}" || echo "no: ${MCP_ELICIT_ACTION}"'
# A step before the question and one after it, for duplicate retries. The
# step after it is slow, so duplicates arrive while it runs: two runs at once
# would both run it (neither has recorded it yet).
add_tool charge 60 '
slow_bump() { sleep 2; bump "$1"; }
mcp_once bump charged >/dev/null
if mcp_elicit_confirm "Ship?"; then
	mcp_once slow_bump shipped >/dev/null
	echo shipped
else
	echo "no: ${MCP_ELICIT_ACTION}"
fi'
# Its journal goes away during the run (here the tool removes it), without
# set -e: the substitution must not carry on with an empty value.
# shellcheck disable=SC2016
add_tool vanish 60 'set +e
v="$(rm -rf "${MCP_MRTR_JOURNAL}"; mcp_once bump gone_step)"
bump after_gone >/dev/null
echo "v=${v}"'
# Its journal goes away and it finishes without the SDK noticing: the server
# alone must refuse its output.
# shellcheck disable=SC2016
add_tool vanish_quiet 60 'rm -rf "${MCP_MRTR_JOURNAL}"
bump quiet_done >/dev/null
echo "finished"'
# A step whose arguments change between runs (here a "token").
# shellcheck disable=SC2016
add_tool secret 60 'mcp_once printf "%s" "token-${MCP_MRTR_ATTEMPT}" >/dev/null
mcp_elicit_confirm "Go?" && echo yes || echo no'

ELICIT_CAPS='{"elicitation":{"form":{}}}'

# req ID PARAMS_JSON [CAPS]: one modern tools/call line.
req() {
	local caps="${3:-${ELICIT_CAPS}}"
	jq -cn --argjson id "$1" --argjson p "$2" --argjson c "${caps}" \
		'{jsonrpc: "2.0", id: $id, method: "tools/call", params: ($p + {_meta: {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": $c}})}'
}

IN_FIFO="${TEST_TMPDIR}/in"
OUT_FIFO="${TEST_TMPDIR}/out"
mkfifo "${IN_FIFO}" "${OUT_FIFO}"
TRANSCRIPT="${TEST_TMPDIR}/transcript.ndjson"
(
	cd "${WS}" || exit 1
	MCPBASH_MODERN_PROTOCOL=true MCPBASH_TOOL_ALLOWLIST='*' MCPBASH_PROJECT_ROOT="${WS}" \
		MCPBASH_TMP_ROOT="${TEST_TMPDIR}/tmproot" ./bin/mcp-bash <"${IN_FIFO}" >"${OUT_FIFO}" 2>"${TEST_TMPDIR}/server.err"
) &
SERVER_PID=$!
mkdir -p "${TEST_TMPDIR}/tmproot"
exec 3>"${IN_FIFO}"
exec 4<"${OUT_FIFO}"
cleanup() {
	exec 3>&- 2>/dev/null || true
	kill "${SERVER_PID}" 2>/dev/null || true
}
trap cleanup EXIT

send() { printf '%s\n' "$1" >&3; }
# wait_for ID: the response to ID (up to 60s); sets RESP and ELAPSED. A
# response read earlier while waiting for another id is in the transcript.
wait_for() {
	local id="$1" start="${SECONDS}"
	RESP=""
	if [ -f "${TRANSCRIPT}" ]; then
		RESP="$(jq -c --argjson id "${id}" 'select(.id == $id)' "${TRANSCRIPT}" 2>/dev/null | tail -n 1)"
		if [ -n "${RESP}" ]; then
			ELAPSED=0
			return 0
		fi
	fi
	while [ $((SECONDS - start)) -lt 60 ]; do
		test_read_line 4 1 || continue
		printf '%s\n' "${TEST_LINE}" >>"${TRANSCRIPT}"
		if printf '%s' "${TEST_LINE}" | jq -e --argjson id "${id}" '.id == $id' >/dev/null 2>&1; then
			RESP="${TEST_LINE}"
			ELAPSED=$((SECONDS - start))
			return 0
		fi
	done
	test_fail "no response to ${id} within 60s"
}
field() { printf '%s' "${RESP}" | jq -r "$1"; }
count() {
	if [ -f "${COUNTS}/$1" ]; then wc -c <"${COUNTS}/$1" | tr -d ' '; else printf 0; fi
}

# --- A question ends the call with input_required, at once -----------------
send "$(req 1 '{"name":"deploy","arguments":{"env":"prod"}}')"
wait_for 1
assert_eq "input_required" "$(field '.result.resultType')" "a question ends the call with input_required"
[ "${ELAPSED}" -le 10 ] || test_fail "input_required took ${ELAPSED}s (the tool's timeout is 60s)"
TICKET="$(field '.result.requestState')"
[[ "${TICKET}" =~ ^[0-9a-f]{32}$ ]] || test_fail "requestState is not a ticket: ${TICKET}"
assert_eq '["q1"]' "$(field '.result.inputRequests | keys | tostring')" "one question, key q1"
assert_eq "elicitation/create" "$(field '.result.inputRequests.q1.method')" "the question is an elicitation"
assert_eq "Deploy wrapped?" "$(field '.result.inputRequests.q1.params.message')" "its message"
assert_eq "form" "$(field '.result.inputRequests.q1.params.mode')" "form mode"
assert_eq "boolean" "$(field '.result.inputRequests.q1.params.requestedSchema.properties.confirmed.type')" "its schema"
assert_eq "null" "$(field '.result.isError // null')" "not an error"
assert_eq "0" "$(count after)" "nothing after the question ran"

# --- A retry without the answer asks again, same ticket --------------------
send "$(req 2 "$(jq -cn --arg t "${TICKET}" '{name: "deploy", arguments: {env: "prod"}, requestState: $t, inputResponses: {}}')")"
wait_for 2
assert_eq "input_required" "$(field '.result.resultType')" "missing answer: asked again"
assert_eq "${TICKET}" "$(field '.result.requestState')" "same ticket"

# --- Other arguments, or an unknown ticket: an error result -----------------
send "$(req 3 "$(jq -cn --arg t "${TICKET}" '{name: "deploy", arguments: {env: "dev"}, requestState: $t, inputResponses: {q1: {action: "accept", content: {confirmed: true}}}}')")"
wait_for 3
assert_eq "true" "$(field '.result.isError')" "other arguments: an error result"
assert_eq "request_mismatch" "$(field '.result._meta["mcpbash/error"].type')" "type request_mismatch"
send "$(req 4 '{"name":"deploy","arguments":{"env":"prod"},"requestState":"0123456789abcdef0123456789abcdef","inputResponses":{"q1":{"action":"accept","content":{"confirmed":true}}}}')"
wait_for 4
assert_eq "request_expired" "$(field '.result._meta["mcpbash/error"].type')" "unknown ticket: request_expired"
send "$(req 5 '{"name":"deploy","arguments":{"env":"prod"},"inputResponses":{"q1":{"action":"accept"}}}')"
wait_for 5
assert_eq "-32602" "$(field '.error.code')" "inputResponses without requestState: invalid params"

# --- The retry with the answer completes; wrapped steps ran once -----------
send "$(req 6 "$(jq -cn --arg t "${TICKET}" '{name: "deploy", arguments: {env: "prod"}, requestState: $t, inputResponses: {q1: {action: "accept", content: {confirmed: true}}}}')")"
wait_for 6
assert_eq "complete" "$(field '.result.resultType')" "the retry completes"
assert_eq "deployed" "$(field '.result.content[0].text' | tr -d '\n')" "the tool saw the answer"
assert_eq "1" "$(count wrapped)" "the mcp_once step ran once"
assert_eq "2" "$(count unwrapped)" "the unwrapped step ran on both runs"
assert_eq "1" "$(count after)" "the step after the question ran once"
# The journal is gone: the same ticket is now unknown.
send "$(req 7 "$(jq -cn --arg t "${TICKET}" '{name: "deploy", arguments: {env: "prod"}, requestState: $t, inputResponses: {q1: {action: "accept", content: {confirmed: true}}}}')")"
wait_for 7
assert_eq "request_expired" "$(field '.result._meta["mcpbash/error"].type')" "a finished call's ticket is gone"

# --- A decline on the retry ----------------------------------------------------
send "$(req 8 '{"name":"deploy","arguments":{"env":"qa"}}')"
wait_for 8
T2="$(field '.result.requestState')"
send "$(req 9 "$(jq -cn --arg t "${T2}" '{name: "deploy", arguments: {env: "qa"}, requestState: $t, inputResponses: {q1: {action: "decline"}}}')")"
wait_for 9
assert_eq "not deployed: decline (attempt 2)" "$(field '.result.content[0].text' | tr -d '\n')" "a decline reaches the tool, on attempt 2"

# --- A tool without timeoutSecs still stops at the question ---------------
send "$(req 10 '{"name":"notimeout","arguments":{}}')"
wait_for 10
assert_eq "input_required" "$(field '.result.resultType')" "no timeoutSecs: input_required"
[ "${ELAPSED}" -le 10 ] || test_fail "no timeoutSecs: input_required took ${ELAPSED}s"

# --- Another path on the retry is an error, never a mis-routed answer -------
send "$(req 11 '{"name":"drift","arguments":{}}')"
wait_for 11
T3="$(field '.result.requestState')"
send "$(req 12 "$(jq -cn --arg t "${T3}" '{name: "drift", arguments: {}, requestState: $t, inputResponses: {q1: {action: "accept", content: {confirmed: true}}}}')")"
wait_for 12
assert_eq "true" "$(field '.result.isError')" "divergence is an error result"
assert_eq "diverged" "$(field '.result._meta["mcpbash/error"].type')" "type diverged"
field '.result.content[0].text' | grep -q 'question 1' || test_fail "the error names the question: $(field '.result.content[0].text')"

# --- A client without elicitation: unavailable, and --arg still answers ----
send "$(req 13 '{"name":"notimeout","arguments":{}}' '{}')"
wait_for 13
assert_eq "complete" "$(field '.result.resultType')" "no elicitation capability: no question"
assert_eq "no: unavailable" "$(field '.result.content[0].text' | tr -d '\n')" "the helper answers unavailable"
send "$(req 14 '{"name":"byarg","arguments":{"name":"Ada"}}')"
wait_for 14
assert_eq "name=Ada" "$(field '.result.content[0].text' | tr -d '\n')" "--arg answers without asking"

# --- Two calls at once get their own journals --------------------------------
send "$(req 15 '{"name":"notimeout","arguments":{"n":1}}')"
send "$(req 16 '{"name":"notimeout","arguments":{"n":2}}')"
wait_for 15
A="$(field '.result.requestState')"
wait_for 16
B="$(field '.result.requestState')"
if [ -z "${A}" ] || [ -z "${B}" ] || [ "${A}" = "${B}" ]; then
	test_fail "concurrent calls share a ticket: ${A} ${B}"
fi

# --- A requestState with a trailing newline is not the ticket -----------------
send "$(req 19 '{"name":"deploy","arguments":{"env":"nl"}}')"
wait_for 19
T4="$(field '.result.requestState')"
send "$(req 20 "$(jq -cn --arg t "${T4}"$'\n' '{name: "deploy", arguments: {env: "nl"}, requestState: $t, inputResponses: {q1: {action: "accept", content: {confirmed: true}}}}')")"
wait_for 20
assert_eq "request_expired" "$(field '.result._meta["mcpbash/error"].type')" "a ticket with a trailing newline is unknown"

# --- A step that changes: the error names its position, not its command ------
send "$(req 21 '{"name":"secret","arguments":{}}')"
wait_for 21
T5="$(field '.result.requestState')"
send "$(req 22 "$(jq -cn --arg t "${T5}" '{name: "secret", arguments: {}, requestState: $t, inputResponses: {q1: {action: "accept", content: {confirmed: true}}}}')")"
wait_for 22
assert_eq "diverged" "$(field '.result._meta["mcpbash/error"].type')" "a changed step is a divergence"
field '.result.content[0].text' | grep -q 'step 1' || test_fail "the error names the step: $(field '.result.content[0].text')"
if printf '%s' "${RESP}" | grep -q 'token-'; then
	test_fail "the divergence sent the step's command line: ${RESP}"
fi
assert_eq "null" "$(field '.result._meta.exitCode')" "no tool exit status for a divergence"

# --- Duplicate retries with one ticket: the tool runs once ------------------
send "$(req 30 '{"name":"charge","arguments":{}}')"
wait_for 30
T6="$(field '.result.requestState')"
for id in 31 32 33 34; do
	send "$(req "${id}" "$(jq -cn --arg t "${T6}" '{name: "charge", arguments: {}, requestState: $t, inputResponses: {q1: {action: "accept", content: {confirmed: true}}}}')")"
done
shipped=0
for id in 31 32 33 34; do
	wait_for "${id}"
	case "$(field '.result.content[0].text // ""' | tr -d '\n')" in
	shipped) shipped=$((shipped + 1)) ;;
	"no: "*) test_fail "a duplicate retry ran the tool without its journal: ${RESP}" ;;
	esac
	case "$(field '.result.resultType'):$(field '.result._meta["mcpbash/error"].type // ""')" in
	complete:"" | input_required:* | complete:request_in_progress | complete:request_expired) ;;
	*) test_fail "unexpected answer to a duplicate retry: ${RESP}" ;;
	esac
	if [ "$(field '.result.resultType')" = "input_required" ]; then
		assert_eq '["q1"]' "$(field '.result.inputRequests | keys | tostring')" "asked again, never with no questions"
	fi
done
assert_eq "1" "${shipped}" "exactly one retry completed"
assert_eq "1" "$(count charged)" "the step before the question ran once"
assert_eq "1" "$(count shipped)" "the step after the question ran once"

# --- A retry that can't ask still gets the answer the user gave -------------
send "$(req 35 '{"name":"notimeout","arguments":{"r":1}}')"
wait_for 35
T7="$(field '.result.requestState')"
send "$(req 36 "$(jq -cn --arg t "${T7}" '{name: "notimeout", arguments: {r: 1}, requestState: $t, inputResponses: {q1: {action: "accept", content: {confirmed: true}}}}')" '{}')"
wait_for 36
assert_eq "go" "$(field '.result.content[0].text' | tr -d '\n')" "a retry without elicitation capabilities reads the journaled answer"

# --- The journal goes away during the run: request_expired, and it stops ----
send "$(req 37 '{"name":"vanish","arguments":{}}')"
wait_for 37
assert_eq "request_expired" "$(field '.result._meta["mcpbash/error"].type')" "a journal gone during the run: request_expired, not the tool's output"
assert_eq "0" "$(count gone_step)" "no step runs without its journal"
assert_eq "0" "$(count after_gone)" "the tool stops, even inside \$(...) without set -e"

send "$(req 38 '{"name":"vanish_quiet","arguments":{}}')"
wait_for 38
assert_eq "request_expired" "$(field '.result._meta["mcpbash/error"].type')" "the server refuses output from a run whose journal went away"

# --- A cancelled call: no response, and its journal is removed -------------
journals() { find "${TEST_TMPDIR}/tmproot" -path '*/journal/*' -maxdepth 4 -type d ! -name run 2>/dev/null | wc -l | tr -d ' '; }
before="$(journals)"
send "$(req 17 '{"name":"slowask","arguments":{}}')"
sleep 1
send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":17}}'
# A ping-like marker: the next call's answer comes after anything for 17.
send "$(req 18 '{"name":"byarg","arguments":{"name":"Z"}}')"
wait_for 18
waited=0
while [ "$(journals)" != "${before}" ] && [ "${waited}" -lt 30 ]; do
	sleep 1
	waited=$((waited + 1))
done
assert_eq "${before}" "$(journals)" "the cancelled call left no journal"
while test_read_line 4 1; do
	printf '%s\n' "${TEST_LINE}" >>"${TRANSCRIPT}"
done
if grep -q '"id":17' "${TRANSCRIPT}"; then
	test_fail "a cancelled call got a response: $(grep '"id":17' "${TRANSCRIPT}")"
fi

# --- No journal could be made: the question is unavailable, never sent -----
# A regular file where the journal directory goes makes mkdir fail.
JROOT="$(find "${TEST_TMPDIR}/tmproot" -type d -name journal 2>/dev/null | head -n 1)"
[ -n "${JROOT}" ] || test_fail "no journal directory found"
mv "${JROOT}" "${JROOT}.away"
: >"${JROOT}"
send "$(req 40 '{"name":"notimeout","arguments":{}}')"
wait_for 40
assert_eq "no: unavailable" "$(field '.result.content[0].text' | tr -d '\n')" "without a journal the question is unavailable"
# At once: not through the legacy question files, which nothing answers on
# this path.
field '.result._meta.stderr // ""' | grep -q 'not configured' || test_fail "the question went to the legacy path: ${RESP}"
rm -f "${JROOT}"
mv "${JROOT}.away" "${JROOT}"

# --- Never a server-to-client request on the modern path -------------------
if [ -n "$(jq -c 'select(.method? != null)' "${TRANSCRIPT}")" ]; then
	test_fail "the server sent a request or notification on the modern path: $(jq -c 'select(.method? != null)' "${TRANSCRIPT}" | head -1)"
fi

printf 'mrtr flow passed\n'
