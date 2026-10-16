#!/usr/bin/env bats
# Unit layer: the question helpers (mcp_elicit_*) in sdk/tool-sdk.sh. Called
# directly: exit 0 means accepted, the answer goes to -v's variable, and
# MCP_ELICIT_ACTION says why when not (decline, cancel, unavailable).

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
	run --separate-stderr mcp_elicit "Name?" '{"type":"object"}' 1
	[[ "${stderr}" == *"Timeout waiting for user response"* ]]
	run --separate-stderr mcp_elicit_url_raw "Sign in" "https://example.com" 1
	[[ "${stderr}" == *"Timeout waiting for user response"* ]]
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
	# confirm reads --arg only when the client can't ask.
	MCP_ELICIT_SUPPORTED=0
	mcp_elicit_confirm --arg go "Go?"
	mcp_elicit_confirm --arg confirmed "Proceed?" || st=$?
	assert_equal "${st}" "1"
	assert_equal "${MCP_ELICIT_ACTION}" "decline"
	# Nothing was asked.
	[ ! -e "${MCP_ELICIT_REQUEST_FILE}" ]
}

@test "elicit: confirm asks the user when the client can, whatever --arg says" {
	local st=0
	MCP_TOOL_ARGS_JSON='{"go":true}'
	answer '{"action":"decline","content":null}'
	mcp_elicit_confirm --arg go "Delete everything?" || st=$?
	assert_equal "${st}" "1"
	assert_equal "${MCP_ELICIT_ACTION}" "decline"
	[ -e "${BATS_TEST_TMPDIR}/asked" ]
	# A question the user leaves unanswered doesn't fall back to --arg.
	MCP_ELICIT_DEFAULT_TIMEOUT=1
	st=0
	mcp_elicit_confirm --arg go "Delete everything?" 2>/dev/null || st=$?
	assert_equal "${st}" "1"
	assert_equal "${MCP_ELICIT_ACTION}" "unavailable"
}

@test "elicit: confirm reads --arg only when the server says the client can't ask" {
	local st v
	MCP_TOOL_ARGS_JSON='{"go":true}'
	# Unset or empty is not "can't ask": nothing stands in for the user.
	for v in unset ""; do
		if [ "${v}" = unset ]; then unset MCP_ELICIT_SUPPORTED; else MCP_ELICIT_SUPPORTED="${v}"; fi
		st=0
		mcp_elicit_confirm --arg go "Delete everything?" 2>/dev/null || st=$?
		assert_equal "${st}" "1"
		assert_equal "${MCP_ELICIT_ACTION}" "unavailable"
	done
	MCP_ELICIT_SUPPORTED=0
	mcp_elicit_confirm --arg go "Delete everything?"
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

# --- Names, validation, edge cases -------------------------------------------

# The names the question helpers declare as locals, read from the source.
helper_locals() {
	awk '
		/^(mcp_elicit[a-z_]*|__mcp_elicit[a-z_]*)\(\) \{/ { inside = 1; next }
		inside && /^}/ { inside = 0; next }
		inside && /^[[:space:]]*local[[:space:]]/ {
			line = $0
			sub(/^[[:space:]]*local[[:space:]]+/, "", line)
			n = split(line, w, /[[:space:]]+/)
			for (i = 1; i <= n; i++) {
				name = w[i]
				sub(/=.*/, "", name)
				if (name ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print name
			}
		}' "${MCPBASH_HOME}/sdk/tool-sdk.sh" | sort -u
}

@test "elicit: every local in the question helpers has the reserved prefix" {
	local names bad=""
	names="$(helper_locals)"
	[ -n "${names}" ] || fail "no locals found: the parser is out of date"
	local n
	for n in ${names}; do
		case "${n}" in __mcp_el_*) ;; *) bad="${bad} ${n}" ;; esac
	done
	[ -z "${bad}" ] || fail "locals without the __mcp_el_ prefix:${bad}"
}

@test "elicit: -v gets the answer whatever the caller's variable is called" {
	local name
	for name in value action message field var arg kind schema filter caller field_name resp path options json_tool enum_json json_bin; do
		answer '{"action":"accept","content":{"choice":"safe"}}'
		unset "${name}" 2>/dev/null || true
		mcp_elicit_choice -v "${name}" "Mode?" explore safe || fail "-v ${name}: not accepted (${MCP_ELICIT_ACTION})"
		assert_equal "${!name}" "safe"
		wait "${RESPONDER}" 2>/dev/null || true
	done
}

@test "elicit: -v refuses the SDK's reserved names and a readonly variable" {
	local name st
	for name in __mcp_el_value _MCP_ELICIT_VAR MCP_ELICIT_ACTION; do
		st=0
		mcp_elicit_string -v "${name}" "Name?" 2>/dev/null || st=$?
		assert_equal "${st}" "1"
		assert_equal "${MCP_ELICIT_ACTION}" "unavailable"
	done
	readonly frozen_answer=x
	st=0
	mcp_elicit_string -v frozen_answer "Name?" 2>/dev/null || st=$?
	assert_equal "${st}" "1"
	assert_equal "${MCP_ELICIT_ACTION}" "unavailable"
}

@test "elicit: --arg must be one of the choices, of the right type; otherwise the user is asked" {
	local c="" st
	for bad in '{"env":"prod; rm -rf /"}' '{"env":1}' '{"env":true}' '{"env":["dev"]}' '{"env":{"x":1}}'; do
		MCP_TOOL_ARGS_JSON="${bad}"
		answer '{"action":"accept","content":{"choice":"staging"}}'
		mcp_elicit_choice -v c --arg env "Env?" dev staging || fail "${bad}: not accepted (${MCP_ELICIT_ACTION})"
		assert_equal "${c}" "staging"
		wait "${RESPONDER}" 2>/dev/null || true
	done
	MCP_TOOL_ARGS_JSON='{"env":"dev"}'
	mcp_elicit_choice -v c --arg env "Env?" dev staging
	assert_equal "${c}" "dev"
	# A client that can't ask: an invalid --arg value is unavailable.
	MCP_ELICIT_SUPPORTED=0
	MCP_TOOL_ARGS_JSON='{"env":"prod"}'
	st=0
	mcp_elicit_choice -v c --arg env "Env?" dev staging 2>/dev/null || st=$?
	assert_equal "${st}" "1"
	assert_equal "${MCP_ELICIT_ACTION}" "unavailable"
}

@test "elicit: multi-choice --arg must be an array of distinct choices" {
	local f="" bad
	for bad in '{"f":[1,"zz"]}' '{"f":["zz"]}' '{"f":"logging"}' '{"f":["logging","logging"]}'; do
		MCP_TOOL_ARGS_JSON="${bad}"
		answer '{"action":"accept","content":{"choices":["caching"]}}'
		mcp_elicit_multi_choice -v f --arg f "F?" logging caching || fail "${bad}: not accepted"
		assert_equal "${f}" '["caching"]'
		wait "${RESPONDER}" 2>/dev/null || true
	done
	MCP_TOOL_ARGS_JSON='{"f":["logging"]}'
	mcp_elicit_multi_choice -v f --arg f "F?" logging caching
	assert_equal "${f}" '["logging"]'
}

@test "elicit: confirm --arg takes a real boolean only" {
	local st
	MCP_ELICIT_SUPPORTED=0
	for bad in '{"ok":"true"}' '{"ok":1}' '{"ok":"yes"}'; do
		MCP_TOOL_ARGS_JSON="${bad}"
		st=0
		mcp_elicit_confirm --arg ok "Go?" 2>/dev/null || st=$?
		assert_equal "${st}" "1"
		assert_equal "${MCP_ELICIT_ACTION}" "unavailable"
	done
	MCP_TOOL_ARGS_JSON='{"ok":true}'
	mcp_elicit_confirm --arg ok "Go?"
}

@test "elicit: a client reply outside the choices, or of the wrong type, is unavailable" {
	local c="stale" st reply
	for reply in '{"action":"accept","content":{"choice":"prod"}}' '{"action":"accept","content":{"choice":7}}' \
		'{"action":"accept","content":{}}' '{"action":"accept"}' '{"action":"accept","content":"x"}'; do
		answer "${reply}"
		st=0
		mcp_elicit_choice -v c "Env?" dev staging || st=$?
		assert_equal "${st}" "1"
		assert_equal "${MCP_ELICIT_ACTION}" "unavailable"
		assert_equal "${c}" ""
		wait "${RESPONDER}" 2>/dev/null || true
	done
	answer '{"action":"accept","content":{"choices":"logging"}}'
	st=0
	mcp_elicit_multi_choice -v c "F?" logging || st=$?
	assert_equal "${st}" "1"
	assert_equal "${MCP_ELICIT_ACTION}" "unavailable"
}

@test "elicit: a string answer that is missing or not a string is unavailable" {
	local name st reply
	for reply in '{"action":"accept","content":{}}' '{"action":"accept","content":{"value":3}}'; do
		answer "${reply}"
		st=0
		mcp_elicit_string -v name "Name?" || st=$?
		assert_equal "${st}" "1"
		assert_equal "${MCP_ELICIT_ACTION}" "unavailable"
		wait "${RESPONDER}" 2>/dev/null || true
	done
}

@test "elicit: a field name is data, never part of the jq program" {
	local email="" st
	answer '{"action":"accept","content":{"e-mail":"a@b.c"}}'
	mcp_elicit_string -v email "Email?" "e-mail"
	assert_equal "${email}" "a@b.c"
	wait "${RESPONDER}" 2>/dev/null || true
	answer '{"action":"accept","content":{"value":"v"}}'
	st=0
	mcp_elicit_string -v email "Email?" 'value + env.HOME' || st=$?
	assert_equal "${st}" "1"
	[[ "${email}" != *"${HOME}"* ]] || fail "the field name ran as jq"
}

@test "elicit: trailing newlines in an answer are kept" {
	local text=""
	answer '{"action":"accept","content":{"value":"two\n\n"}}'
	mcp_elicit_string -v text "Text?"
	assert_equal "${text}" $'two\n\n'
}

@test "elicit: a choice helper with no options is unavailable" {
	local st=0 c
	# A client that would answer anything: the helper must not ask at all.
	answer '{"action":"accept","content":{"choice":"x"}}'
	mcp_elicit_choice -v c "Pick" 2>/dev/null || st=$?
	assert_equal "${st}" "1"
	assert_equal "${MCP_ELICIT_ACTION}" "unavailable"
	[ ! -e "${BATS_TEST_TMPDIR}/asked" ]
}

@test "elicit: raw helpers exit non-zero when the client's reply was an error" {
	# The server turns a client error into an "unavailable" reply: no answer.
	answer '{"action":"unavailable","content":null}'
	run mcp_elicit "Name?" '{"type":"object"}'
	assert_failure
	assert_output '{"action":"unavailable","content":null}'
	answer '{"action":"unavailable","content":null}'
	run mcp_elicit_url_raw "Sign in" "https://example.com"
	assert_failure
	assert_output '{"action":"unavailable","content":null}'
	# A decline is an answer.
	answer '{"action":"decline","content":null}'
	run mcp_elicit "Name?" '{"type":"object"}'
	assert_success
	# So is an accepted answer whose own field is called action.
	answer '{"action":"accept","content":{"action":"unavailable"}}'
	run mcp_elicit "Status?" '{"type":"object","properties":{"action":{"type":"string"}}}'
	assert_success
}
