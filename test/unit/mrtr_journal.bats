#!/usr/bin/env bats
# Unit layer: the server side of multi round-trip requests (lib/mrtr.sh).
# Each modern tools/call gets a journal under the state dir, named by a random
# ticket that the client echoes as requestState. A retry is checked (ticket,
# expiry, tool and arguments) before its answers go into the journal.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable"
	fi
	# shellcheck source=lib/ids.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/ids.sh"
	# shellcheck source=lib/lock.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/lock.sh"
	# shellcheck source=lib/mrtr.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/mrtr.sh"
	MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	mkdir -p "${MCPBASH_STATE_DIR}"
}

# A first call of tool t, then the question it asked (q.1).
first_call() {
	mcp_mrtr_open t '{"b":1,"a":{"y":2,"x":1}}' "" "" 1 1
	assert_equal "${MCP_MRTR_OUTCOME}" "run"
	printf '%s' '{"mode":"form","message":"Go?","requestedSchema":{"type":"object","properties":{"confirmed":{"type":"boolean"}}}}' >"${MCP_MRTR_DIR}/q.1.req"
	cp "${MCP_MRTR_DIR}/q.1.req" "${MCP_MRTR_DIR}/q.1.sig"
	printf '3' >"${MCP_MRTR_DIR}/pos.step"
	printf 'input_required' >"${MCP_MRTR_DIR}/stop"
	# The run ended: the server releases the journal when it answers.
	mcp_mrtr_release "${MCP_MRTR_DIR}"
	TICKET="${MCP_MRTR_TICKET}"
	DIR="${MCP_MRTR_DIR}"
}

@test "mrtr journal: a ticket is 32 lowercase hex characters, new every time" {
	local a b
	a="$(mcp_mrtr_new_ticket)"
	b="$(mcp_mrtr_new_ticket)"
	[[ "${a}" =~ ^[0-9a-f]{32}$ ]]
	[ "${a}" != "${b}" ]
}

@test "mrtr journal: a requestState that isn't a ticket never reaches the file system" {
	local t
	for t in ../../etc 0123456789ABCDEF0123456789abcdef 0123456789abcdef0123456789abcde "" "0123456789abcdef0123456789abcdef/.."; do
		run mcp_mrtr_valid_ticket "${t}"
		assert_failure
	done
	run mcp_mrtr_valid_ticket 0123456789abcdef0123456789abcdef
	assert_success
}

@test "mrtr journal: the arguments digest ignores key order, not values" {
	local a b c
	a="$(mcp_mrtr_args_digest '{"b":1,"a":{"y":2,"x":1}}')"
	b="$(mcp_mrtr_args_digest '{"a":{"x":1,"y":2},"b":1}')"
	c="$(mcp_mrtr_args_digest '{"a":{"x":1,"y":3},"b":1}')"
	[ -n "${a}" ]
	assert_equal "${a}" "${b}"
	[ "${a}" != "${c}" ]
	assert_equal "$(mcp_mrtr_args_digest '')" "$(mcp_mrtr_args_digest '{}')"
}

@test "mrtr journal: the arguments digest doesn't depend on how a number is written" {
	assert_equal "$(mcp_mrtr_args_digest '{"n":1.0,"m":[1e2]}')" "$(mcp_mrtr_args_digest '{"n":1,"m":[100]}')"
	[ "$(mcp_mrtr_args_digest '{"n":1.5}')" != "$(mcp_mrtr_args_digest '{"n":1}')" ]
}

@test "mrtr journal: a first call gets a fresh journal in the state dir" {
	first_call
	[[ "${TICKET}" =~ ^[0-9a-f]{32}$ ]]
	assert_equal "${DIR}" "${MCPBASH_STATE_DIR}/journal/${TICKET}"
	assert_equal "${MCP_MRTR_ATTEMPT}" "1"
	assert_equal "$(cat "${DIR}/modes")" "1 1"
	run ls -ld "${DIR}"
	assert_output --regexp '^drwx------'
	assert_equal "$(cat "${DIR}/name")" "t"
}

@test "mrtr journal: inputResponses without requestState is invalid params" {
	mcp_mrtr_open t '{}' "" '{"q1":{"action":"accept"}}' 1 1
	assert_equal "${MCP_MRTR_OUTCOME}" "invalid"
	[ ! -d "${MCPBASH_STATE_DIR}/journal" ] || [ -z "$(ls -A "${MCPBASH_STATE_DIR}/journal")" ]
}

@test "mrtr journal: an unknown or malformed ticket is an expired request" {
	mcp_mrtr_open t '{}' 0123456789abcdef0123456789abcdef '{}' 1 1
	assert_equal "${MCP_MRTR_OUTCOME}" "error"
	assert_equal "${MCP_MRTR_ERROR_TYPE}" "request_expired"
	mcp_mrtr_open t '{}' ../../etc '{}' 1 1
	assert_equal "${MCP_MRTR_OUTCOME}" "error"
	assert_equal "${MCP_MRTR_ERROR_TYPE}" "request_expired"
}

@test "mrtr journal: a ticket older than the TTL is expired and removed" {
	first_call
	printf '%s' "$(($(date +%s) - 1000))" >"${DIR}/created"
	MCPBASH_MRTR_TICKET_TTL_SECS=900 mcp_mrtr_open t '{"a":{"x":1,"y":2},"b":1}' "${TICKET}" '{"q1":{"action":"accept","content":{"confirmed":true}}}' 1 1
	assert_equal "${MCP_MRTR_OUTCOME}" "error"
	assert_equal "${MCP_MRTR_ERROR_TYPE}" "request_expired"
	[ ! -d "${DIR}" ]
}

@test "mrtr journal: a retry for another tool or other arguments is refused" {
	first_call
	mcp_mrtr_open other '{"a":{"x":1,"y":2},"b":1}' "${TICKET}" '{}' 1 1
	assert_equal "${MCP_MRTR_OUTCOME}" "error"
	assert_equal "${MCP_MRTR_ERROR_TYPE}" "request_mismatch"
	mcp_mrtr_open t '{"a":{"x":1,"y":2},"b":2}' "${TICKET}" '{}' 1 1
	assert_equal "${MCP_MRTR_OUTCOME}" "error"
	assert_equal "${MCP_MRTR_ERROR_TYPE}" "request_mismatch"
	# The journal is kept for the right retry.
	[ -d "${DIR}" ]
}

@test "mrtr journal: a retry with the answer records it and runs again" {
	first_call
	mcp_mrtr_open t '{"a":{"x":1,"y":2},"b":1}' "${TICKET}" '{"q1":{"action":"accept","content":{"confirmed":true}}}' 1 1
	assert_equal "${MCP_MRTR_OUTCOME}" "run"
	assert_equal "${MCP_MRTR_DIR}" "${DIR}"
	assert_equal "${MCP_MRTR_ATTEMPT}" "2"
	assert_equal "$(jq -c '[.action, .content.confirmed]' "${DIR}/q.1.ans")" '["accept",true]'
	[ ! -e "${DIR}/stop" ]
	[ ! -e "${DIR}/pos.step" ]
}

@test "mrtr journal: answers are normalised like the legacy path" {
	first_call
	mcp_mrtr_open t '{"a":{"x":1,"y":2},"b":1}' "${TICKET}" '{"q1":{"action":"maybe","content":"x"}}' 1 1
	assert_equal "$(cat "${DIR}/q.1.ans")" '{"action":"unavailable","content":null}'
}

@test "mrtr journal: a retry without the answer asks again, same ticket" {
	first_call
	mcp_mrtr_open t '{"a":{"x":1,"y":2},"b":1}' "${TICKET}" '{"other":{"action":"accept"}}' 1 1
	assert_equal "${MCP_MRTR_OUTCOME}" "input_required"
	run mcp_mrtr_pending_result "${DIR}" "${TICKET}"
	assert_success
	assert_equal "$(printf '%s' "${output}" | jq -c '[.resultType, .requestState, (.inputRequests | keys), .inputRequests.q1.method, .inputRequests.q1.params.message]')" \
		"[\"input_required\",\"${TICKET}\",[\"q1\"],\"elicitation/create\",\"Go?\"]"
}

@test "mrtr journal: a call holds its journal while it runs; release frees it" {
	mcp_mrtr_open t '{}' "" "" 1 1
	[ -d "${MCP_MRTR_DIR}/run" ]
	mcp_mrtr_release "${MCP_MRTR_DIR}"
	[ ! -e "${MCP_MRTR_DIR}/run" ]
}

@test "mrtr journal: of two retries with one ticket, only the first runs" {
	first_call
	local answer='{"q1":{"action":"accept","content":{"confirmed":true}}}'
	mcp_mrtr_open t '{"a":{"x":1,"y":2},"b":1}' "${TICKET}" "${answer}" 1 1
	assert_equal "${MCP_MRTR_OUTCOME}" "run"
	MCPBASH_MRTR_INFLIGHT_WAIT_SECS=1 mcp_mrtr_open t '{"a":{"x":1,"y":2},"b":1}' "${TICKET}" "${answer}" 1 1
	assert_equal "${MCP_MRTR_OUTCOME}" "error"
	assert_equal "${MCP_MRTR_ERROR_TYPE}" "request_in_progress"
	assert_equal "$(cat "${DIR}/attempt")" "2"
}

@test "mrtr journal: a retry that waits on a run with open questions is asked them again" {
	first_call
	mcp_mrtr_claim "${DIR}"
	MCPBASH_MRTR_INFLIGHT_WAIT_SECS=1 mcp_mrtr_open t '{"a":{"x":1,"y":2},"b":1}' "${TICKET}" '{"q1":{"action":"accept","content":{"confirmed":true}}}' 1 1
	assert_equal "${MCP_MRTR_OUTCOME}" "input_required"
	[ ! -e "${DIR}/q.1.ans" ]
}

@test "mrtr journal: a journal removed while a retry waits is expired, never an empty question list" {
	first_call
	mcp_mrtr_claim "${DIR}"
	(
		sleep 0.3
		rm -rf "${DIR:?}"
	) &
	MCPBASH_MRTR_INFLIGHT_WAIT_SECS=3 mcp_mrtr_open t '{"a":{"x":1,"y":2},"b":1}' "${TICKET}" '{"q1":{"action":"accept","content":{"confirmed":true}}}' 1 1
	wait
	assert_equal "${MCP_MRTR_OUTCOME}" "error"
	assert_equal "${MCP_MRTR_ERROR_TYPE}" "request_expired"
}

@test "mrtr journal: the sweep keeps a journal while its run is alive, and counts the TTL from the last round" {
	first_call
	mcp_mrtr_claim "${DIR}"
	printf '%s' "$(($(date +%s) - 1000))" >"${DIR}/created"
	MCPBASH_MRTR_TICKET_TTL_SECS=900 mcp_mrtr_sweep
	[ -d "${DIR}" ]
	# Released after asking again: a new round starts now.
	mcp_mrtr_release "${DIR}"
	MCPBASH_MRTR_TICKET_TTL_SECS=900 mcp_mrtr_sweep
	[ -d "${DIR}" ]
	printf '%s' "$(($(date +%s) - 1000))" >"${DIR}/created"
	MCPBASH_MRTR_TICKET_TTL_SECS=900 mcp_mrtr_sweep
	[ ! -d "${DIR}" ]
}

@test "mrtr journal: a claim left by a process that ended doesn't keep its journal past the TTL" {
	(
		mcp_mrtr_open t '{}' "" "" 1 1
		printf '%s' "${MCP_MRTR_DIR}" >"${BATS_TEST_TMPDIR}/dir"
	)
	local d
	d="$(cat "${BATS_TEST_TMPDIR}/dir")"
	[ -d "${d}/run" ]
	printf '%s' "$(($(date +%s) - 1000))" >"${d}/created"
	MCPBASH_MRTR_TICKET_TTL_SECS=900 mcp_mrtr_sweep
	[ ! -d "${d}" ]
}

@test "mrtr journal: journal files are private whatever the umask" {
	umask 022
	first_call
	mcp_mrtr_open t '{"a":{"x":1,"y":2},"b":1}' "${TICKET}" '{"q1":{"action":"accept","content":{"confirmed":true}}}' 1 1
	local f
	for f in name digest created attempt modes q.1.ans; do
		run ls -l "${DIR}/${f}"
		assert_output --regexp '^-rw-------'
	done
}

@test "mrtr journal: after a run, the stop marker says how it ended" {
	first_call
	assert_equal "$(mcp_mrtr_run_outcome "${DIR}")" "input_required"
	printf 'diverged' >"${DIR}/stop"
	assert_equal "$(mcp_mrtr_run_outcome "${DIR}")" "diverged"
	rm -f "${DIR}/stop"
	assert_equal "$(mcp_mrtr_run_outcome "${DIR}")" "complete"
	mcp_mrtr_close "${DIR}"
	[ ! -d "${DIR}" ]
}
