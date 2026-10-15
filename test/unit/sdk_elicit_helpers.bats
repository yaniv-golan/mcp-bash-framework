#!/usr/bin/env bats
# Unit layer: the question helpers (mcp_elicit_*) in sdk/tool-sdk.sh. Called
# directly: exit 0 means accepted, the answer goes to -v's variable, and
# MCP_ELICIT_ACTION says why when not (decline, cancel, unavailable).

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
		skip "JSON tooling unavailable for SDK helper tests"
	fi
	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"
	MCP_ELICIT_SUPPORTED=1
	MCP_ELICIT_REQUEST_FILE="${BATS_TEST_TMPDIR}/request"
	MCP_ELICIT_RESPONSE_FILE="${BATS_TEST_TMPDIR}/response"
	MCP_ELICIT_DEFAULT_TIMEOUT=5
	MCP_TOOL_ARGS_JSON='{}'
	RESPONDER=""
}

teardown() {
	[ -z "${RESPONDER}" ] || kill "${RESPONDER}" 2>/dev/null || true
}

# Answer the next question with $1 (the client's result), as the server does.
answer() {
	(
		n=0
		while [ ! -f "${MCP_ELICIT_REQUEST_FILE}" ] && [ "${n}" -lt 50 ]; do
			sleep 0.1
			n=$((n + 1))
		done
		cp "${MCP_ELICIT_REQUEST_FILE}" "${BATS_TEST_TMPDIR}/asked"
		rm -f "${MCP_ELICIT_REQUEST_FILE}"
		printf '%s' "$1" >"${MCP_ELICIT_RESPONSE_FILE}"
	) &
	RESPONDER=$!
}

@test "elicit: confirm accepted and confirmed is exit 0" {
	answer '{"action":"accept","content":{"confirmed":true}}'
	mcp_elicit_confirm "Proceed?"
	assert_equal "${MCP_ELICIT_ACTION}" "accept"
}

@test "elicit: confirm accepted but not confirmed is a decline" {
	answer '{"action":"accept","content":{"confirmed":false}}'
	run_status=0
	mcp_elicit_confirm "Proceed?" || run_status=$?
	assert_equal "${run_status}" "1"
	assert_equal "${MCP_ELICIT_ACTION}" "decline"
}

@test "elicit: a decline and a cancel are exit 1 with the action" {
	local action st
	for action in decline cancel; do
		answer "{\"action\":\"${action}\"}"
		st=0
		mcp_elicit_confirm "Proceed?" || st=$?
		assert_equal "${st}" "1"
		assert_equal "${MCP_ELICIT_ACTION}" "${action}"
		wait "${RESPONDER}" 2>/dev/null || true
	done
}

@test "elicit: a client that can't ask is unavailable, for the helpers and raw mcp_elicit" {
	MCP_ELICIT_SUPPORTED=0
	local st=0
	mcp_elicit_confirm "Proceed?" 2>/dev/null || st=$?
	assert_equal "${st}" "1"
	assert_equal "${MCP_ELICIT_ACTION}" "unavailable"
	run mcp_elicit "Proceed?" '{"type":"object"}'
	assert_failure
	assert_output --partial '"action":"unavailable"'
}

@test "elicit: a timeout is unavailable, never action error" {
	MCP_ELICIT_DEFAULT_TIMEOUT=1
	local st=0
	mcp_elicit_string -v name "Name?" 2>/dev/null || st=$?
	assert_equal "${st}" "1"
	assert_equal "${MCP_ELICIT_ACTION}" "unavailable"
	run mcp_elicit "Name?" '{"type":"object"}' 1
	refute_output --partial '"error"'
}

@test "elicit: string, choice and titled choice put the answer in -v's variable" {
	local name="" mode="" quality=""
	answer '{"action":"accept","content":{"value":"Ada"}}'
	mcp_elicit_string -v name "Name?"
	assert_equal "${name}" "Ada"
	wait "${RESPONDER}" 2>/dev/null || true
	answer '{"action":"accept","content":{"choice":"safe"}}'
	mcp_elicit_choice -v mode "Mode?" explore safe expert
	assert_equal "${mode}" "safe"
	wait "${RESPONDER}" 2>/dev/null || true
	answer '{"action":"accept","content":{"choice":"high"}}'
	mcp_elicit_titled_choice -v quality "Quality?" "high:High" "low:Low"
	assert_equal "${quality}" "high"
	# The question asked for a titled choice.
	run cat "${BATS_TEST_TMPDIR}/asked"
	assert_output --partial '"oneOf":[{"const":"high","title":"High"}'
}

@test "elicit: a custom field name for string" {
	local email=""
	answer '{"action":"accept","content":{"email":"a@b.c"}}'
	mcp_elicit_string -v email "Email?" email
	assert_equal "${email}" "a@b.c"
}

@test "elicit: multi-choice answers are a compact JSON array" {
	local features=""
	answer '{"action":"accept","content":{"choices":["logging","caching"]}}'
	mcp_elicit_multi_choice -v features "Features?" logging caching compression
	assert_equal "${features}" '["logging","caching"]'
}

@test "elicit: -v's variable is emptied when not accepted" {
	local name="stale"
	answer '{"action":"decline"}'
	mcp_elicit_string -v name "Name?" || true
	assert_equal "${name}" ""
}

@test "elicit: --arg answers from the call's arguments, without asking" {
	local name="" st=0
	MCP_TOOL_ARGS_JSON='{"name":"Grace","confirmed":false,"go":true}'
	mcp_elicit_string -v name --arg name "Name?"
	assert_equal "${name}" "Grace"
	assert_equal "${MCP_ELICIT_ACTION}" "accept"
	mcp_elicit_confirm --arg go "Go?"
	mcp_elicit_confirm --arg confirmed "Proceed?" || st=$?
	assert_equal "${st}" "1"
	assert_equal "${MCP_ELICIT_ACTION}" "decline"
	# Nothing was asked.
	[ ! -e "${MCP_ELICIT_REQUEST_FILE}" ]
}

@test "elicit: --arg that the call doesn't have asks" {
	local name=""
	MCP_TOOL_ARGS_JSON='{"other":1}'
	answer '{"action":"accept","content":{"value":"Asked"}}'
	mcp_elicit_string -v name --arg name "Name?"
	assert_equal "${name}" "Asked"
}

@test "elicit: -v with something that isn't a variable name is refused" {
	local st=0
	mcp_elicit_string -v 'bad name' "Name?" 2>/dev/null || st=$?
	assert_equal "${st}" "1"
	assert_equal "${MCP_ELICIT_ACTION}" "unavailable"
}

@test "elicit: url is exit 0 when accepted" {
	answer '{"action":"accept"}'
	mcp_elicit_url "Sign in" "https://example.com/auth"
	assert_equal "${MCP_ELICIT_ACTION}" "accept"
}
