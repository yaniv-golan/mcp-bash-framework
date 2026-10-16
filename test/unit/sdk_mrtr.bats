#!/usr/bin/env bats
# Unit layer: the SDK side of multi round-trip requests (2026-07-28). With
# MCP_MRTR_JOURNAL set (the server sets it for a modern tools/call), mcp_once
# records each step and replays it on the retry, and a question is written to
# the journal and blocks until the server stops the tool.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

bats_require_minimum_version 1.5.0

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable for SDK helper tests"
	fi
	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"
	J="${BATS_TEST_TMPDIR}/journal"
	mkdir -p "${J}"
	printf '1 1' >"${J}/modes"
	MCP_MRTR_JOURNAL="${J}"
	MCP_ELICIT_SUPPORTED=1
	MCP_TOOL_ARGS_JSON='{}'
	COUNT="${BATS_TEST_TMPDIR}/count"
	: >"${COUNT}"
	BLOCKED=""
}

# Stop a blocked call and everything it started (the server stops the
# tool's whole process group).
kill_tree() {
	local child
	for child in $(pgrep -P "$1" 2>/dev/null); do
		kill_tree "${child}"
	done
	kill "$1" 2>/dev/null || true
}

teardown() {
	[ -z "${BLOCKED}" ] || kill_tree "${BLOCKED}"
}

# A new run of the same call: the server resets the positions.
next_run() {
	rm -f "${J}/pos.step" "${J}/pos.q" "${J}/stop"
}

side_effect() {
	printf 'x' >>"${COUNT}"
	printf 'out:%s\n' "$1"
	printf 'err:%s\n' "$1" >&2
	return "${2:-0}"
}

# Run "$@" in the background; wait (up to 5s) for the stop marker.
run_until_stop() {
	"$@" >"${BATS_TEST_TMPDIR}/blocked.out" 2>/dev/null 3>&- &
	BLOCKED=$!
	local n=0
	while [ ! -s "${J}/stop" ] && [ "${n}" -lt 50 ]; do
		sleep 0.1
		n=$((n + 1))
	done
	[ -s "${J}/stop" ]
	# Still blocked: nothing after the question ran.
	kill -0 "${BLOCKED}"
}

@test "mrtr: mcp_once runs a step once and replays stdout, stderr and the exit code" {
	local st=0
	run --separate-stderr mcp_once side_effect a 3
	assert_equal "${status}" "3"
	assert_equal "${output}" "out:a"
	assert_equal "${stderr}" "err:a"
	next_run
	run --separate-stderr mcp_once side_effect a 3
	assert_equal "${status}" "3"
	assert_equal "${output}" "out:a"
	assert_equal "${stderr}" "err:a"
	assert_equal "$(cat "${COUNT}")" "x"
}

@test "mrtr: replayed output is byte for byte, trailing newlines and NUL included" {
	emit() { printf 'a\0b\n\n'; }
	mcp_once emit >"${BATS_TEST_TMPDIR}/first"
	next_run
	mcp_once emit >"${BATS_TEST_TMPDIR}/second"
	cmp "${BATS_TEST_TMPDIR}/first" "${BATS_TEST_TMPDIR}/second"
	assert_equal "$(od -An -tx1 "${BATS_TEST_TMPDIR}/second" | tr -d ' \n')" "6100620a0a"
}

@test "mrtr: steps are counted across \$(...) and loops" {
	local v1 v2 i
	v1="$(mcp_once side_effect one)"
	for i in 1 2; do mcp_once side_effect "loop${i}" >/dev/null 2>&1; done
	v2="$(mcp_once side_effect two 2>/dev/null)"
	next_run
	assert_equal "$(mcp_once side_effect one 2>/dev/null)" "${v1}"
	for i in 1 2; do mcp_once side_effect "loop${i}" >/dev/null 2>&1; done
	assert_equal "$(mcp_once side_effect two 2>/dev/null)" "${v2}"
	assert_equal "$(cat "${COUNT}")" "xxxx"
}

@test "mrtr: a step runs in a subshell, in either run" {
	local here="${PWD}"
	set_things() { cd / && STEP_VAR=changed && export STEP_EXPORT=changed; }
	STEP_VAR=orig
	mcp_once set_things
	assert_equal "${PWD}" "${here}"
	assert_equal "${STEP_VAR}" "orig"
	assert_equal "${STEP_EXPORT:-}" ""
	next_run
	mcp_once set_things
	assert_equal "${PWD}" "${here}"
	assert_equal "${STEP_VAR}" "orig"
}

@test "mrtr: without a journal, mcp_once just runs the step, every time, in a subshell" {
	unset MCP_MRTR_JOURNAL
	STEP_VAR=orig
	set_var() { STEP_VAR=changed; side_effect "$@"; }
	run --separate-stderr mcp_once set_var a 2
	assert_equal "${status}" "2"
	assert_equal "${output}" "out:a"
	mcp_once set_var a >/dev/null 2>&1
	assert_equal "${STEP_VAR}" "orig"
	assert_equal "$(cat "${COUNT}")" "xx"
	[ -z "$(ls -A "${J}" | grep -v '^modes$')" ]
}

@test "mrtr: a different step on the retry stops the tool as diverged" {
	mcp_once side_effect a >/dev/null 2>&1
	next_run
	run_until_stop mcp_once side_effect b
	assert_equal "$(cat "${J}/stop")" "diverged"
	run cat "${J}/diverged"
	assert_output --partial "step 1"
	assert_output --partial "side_effect a"
	assert_output --partial "side_effect b"
	# The new step never ran.
	assert_equal "$(cat "${COUNT}")" "x"
}

@test "mrtr: --key names a step, so changing arguments don't count as a new path" {
	mcp_once --key stamp side_effect "$(date +%s%N)" >/dev/null 2>&1
	next_run
	mcp_once --key stamp side_effect "different" >/dev/null 2>&1
	assert_equal "$(cat "${COUNT}")" "x"
	[ ! -e "${J}/stop" ]
}

@test "mrtr: a question with no answer yet is journaled and blocks" {
	run_until_stop mcp_elicit_confirm "Delete it?"
	assert_equal "$(cat "${J}/stop")" "input_required"
	run jq -c '[.mode, .message, (.requestedSchema.properties | keys)]' "${J}/q.1.req"
	assert_output '["form","Delete it?",["confirmed"]]'
	[ ! -s "${BATS_TEST_TMPDIR}/blocked.out" ]
}

@test "mrtr: on the retry the journaled answer is returned without asking" {
	run_until_stop mcp_elicit_string "Name?"
	kill_tree "${BLOCKED}"
	BLOCKED=""
	printf '%s' '{"action":"accept","content":{"value":"Grace"}}' >"${J}/q.1.ans"
	next_run
	local name=""
	mcp_elicit_string -v name "Name?"
	assert_equal "${name}" "Grace"
	assert_equal "${MCP_ELICIT_ACTION}" "accept"
	[ ! -e "${J}/stop" ]
}

@test "mrtr: a declined answer on the retry is a decline" {
	run_until_stop mcp_elicit_confirm "Go?"
	kill_tree "${BLOCKED}"
	BLOCKED=""
	printf '%s' '{"action":"decline","content":null}' >"${J}/q.1.ans"
	next_run
	local st=0
	mcp_elicit_confirm "Go?" || st=$?
	assert_equal "${st}" "1"
	assert_equal "${MCP_ELICIT_ACTION}" "decline"
}

@test "mrtr: steps before a question replay; the step after it runs once, on the retry" {
	flow() {
		mcp_once side_effect before >/dev/null 2>&1
		mcp_elicit_confirm "Go?" || return 1
		mcp_once side_effect after >/dev/null 2>&1
	}
	run_until_stop flow
	kill_tree "${BLOCKED}"
	BLOCKED=""
	assert_equal "$(cat "${COUNT}")" "x"
	printf '%s' '{"action":"accept","content":{"confirmed":true}}' >"${J}/q.1.ans"
	next_run
	flow
	assert_equal "$(cat "${COUNT}")" "xx"
}

@test "mrtr: a different question on the retry stops the tool as diverged" {
	run_until_stop mcp_elicit_confirm "Delete a?"
	kill_tree "${BLOCKED}"
	BLOCKED=""
	printf '%s' '{"action":"accept","content":{"confirmed":true}}' >"${J}/q.1.ans"
	next_run
	run_until_stop mcp_elicit_confirm "Delete b?"
	assert_equal "$(cat "${J}/stop")" "diverged"
	run cat "${J}/diverged"
	assert_output --partial "question 1"
}

@test "mrtr: a URL question is journaled in URL mode" {
	run_until_stop mcp_elicit_url "Sign in" "https://example.com/login"
	run jq -c '[.mode, .message, .url]' "${J}/q.1.req"
	assert_output '["url","Sign in","https://example.com/login"]'
	run jq -r '.elicitationId' "${J}/q.1.req"
	assert_output --regexp '^elicit-'
}

@test "mrtr: a mode the client lacks is unavailable, not asked" {
	printf '1 0' >"${J}/modes"
	local st=0
	mcp_elicit_url "Sign in" "https://example.com/login" 2>/dev/null || st=$?
	assert_equal "${st}" "1"
	assert_equal "${MCP_ELICIT_ACTION}" "unavailable"
	[ ! -e "${J}/stop" ]
	[ ! -e "${J}/q.1.req" ]
}

@test "mrtr: --arg still answers without asking" {
	MCP_TOOL_ARGS_JSON='{"name":"Ada"}'
	local name=""
	mcp_elicit_string -v name --arg name "Name?"
	assert_equal "${name}" "Ada"
	[ ! -e "${J}/stop" ]
}
