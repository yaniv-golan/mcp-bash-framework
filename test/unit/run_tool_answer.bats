#!/usr/bin/env bats
# Unit layer: run-tool answers a tool's questions the way a 2026-07-28 client
# does. A question ends the run with input_required; run-tool calls again with
# the next --answer, the tool runs again from the start, and steps wrapped in
# mcp_once replay. A trace of the runs goes to stderr.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

bats_require_minimum_version 1.5.0

setup() {
	PROJECT_ROOT="${BATS_TEST_TMPDIR}/proj"
	export MCPBASH_PROJECT_ROOT="${PROJECT_ROOT}"
	mkdir -p "${PROJECT_ROOT}/server.d"
	printf '{"name":"answers"}\n' >"${PROJECT_ROOT}/server.d/server.meta.json"
	COUNT="${PROJECT_ROOT}/count"
	: >"${COUNT}"
}

# add_tool NAME BODY: a tool whose body can call bump (a counted step).
add_tool() {
	mkdir -p "${PROJECT_ROOT}/tools/$1"
	printf '{"name":"%s","description":"t","inputSchema":{"type":"object"},"timeoutSecs":60}\n' "$1" >"${PROJECT_ROOT}/tools/$1/tool.meta.json"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\nsource "${MCP_SDK}/tool-sdk.sh"\n'
		printf 'bump() { printf x >>"%s"; printf "%%s" "$1"; }\n' "${COUNT}"
		printf '%s\n' "$2"
	} >"${PROJECT_ROOT}/tools/$1/tool.sh"
	chmod +x "${PROJECT_ROOT}/tools/$1/tool.sh"
}

run_tool() {
	run --separate-stderr "${MCPBASH_HOME}/bin/mcp-bash" run-tool "$@" --allow-self
}

# The text of the single result object on stdout.
result_text() {
	[ "$(printf '%s\n' "${output}" | jq -s 'length')" = "1" ]
	printf '%s' "${output}" | jq -r '.content[0].text'
}

deploy_tool() {
	add_tool deploy 'v="$(mcp_once bump v1)"
if mcp_elicit_confirm "Deploy ${v}?"; then echo "deployed ${v}"; else echo "no: ${MCP_ELICIT_ACTION}"; fi'
}

@test "run_tool_answer: a question with no --answer stops with input_required and names it" {
	deploy_tool
	run_tool deploy
	assert_failure 1
	[ "$(printf '%s\n' "${output}" | jq -s 'length')" = "1" ]
	assert_equal "$(printf '%s' "${output}" | jq -r '.resultType')" "input_required"
	assert_equal "$(printf '%s' "${output}" | jq -r '.inputRequests.q1.params.message')" "Deploy v1?"
	[[ "${stderr}" == *"question 1"* ]]
	[[ "${stderr}" == *"Deploy v1?"* ]]
	[[ "${stderr}" == *"--answer"* ]]
	[[ "${stderr}" == *"confirmed"* ]]
	[[ "${stderr}" == *"run 1: 1 step executed, stopped at question 1"* ]]
}

@test "run_tool_answer: --answer FIELD=VALUE answers, the wrapped step runs once, and the trace shows the replay" {
	deploy_tool
	run_tool deploy --answer confirmed=true
	assert_success
	assert_equal "$(result_text)" "deployed v1"
	assert_equal "$(cat "${COUNT}")" "x"
	[[ "${stderr}" == *"run 1: 1 step executed, stopped at question 1"* ]]
	[[ "${stderr}" == *"run 2: 1 step replayed, completed"* ]]
}

@test "run_tool_answer: a bare value fills a question's only field" {
	deploy_tool
	run_tool deploy --answer true
	assert_success
	assert_equal "$(result_text)" "deployed v1"
}

@test "run_tool_answer: decline and cancel are answers" {
	deploy_tool
	run_tool deploy --answer decline
	assert_success
	assert_equal "$(result_text)" "no: decline"
	run_tool deploy --answer cancel
	assert_success
	assert_equal "$(result_text)" "no: cancel"
}

@test "run_tool_answer: answers go to questions in the order asked; a JSON object is the content as is" {
	add_tool two 'mcp_once bump a >/dev/null
mcp_elicit_confirm "Go?" || { echo "no"; exit 0; }
mcp_once bump b >/dev/null
mcp_elicit_string -v who "Who?" || { echo "no who"; exit 0; }
mcp_once bump c >/dev/null
echo "hi ${who}"'
	run_tool two --answer true --answer '{"value":"Ada, Grace"}'
	assert_success
	assert_equal "$(result_text)" "hi Ada, Grace"
	assert_equal "$(cat "${COUNT}")" "xxx"
	[[ "${stderr}" == *"run 1: 1 step executed, stopped at question 1"* ]]
	[[ "${stderr}" == *"run 2: 1 step replayed, 1 executed, stopped at question 2"* ]]
	[[ "${stderr}" == *"run 3: 2 steps replayed, 1 executed, completed"* ]]
}

@test "run_tool_answer: a value is typed by the question's schema, and a wrong one is refused before the retry" {
	deploy_tool
	run_tool deploy --answer confirmed=maybe
	assert_failure 1
	[[ "${stderr}" == *"confirmed"* ]]
	[[ "${stderr}" == *"true or false"* ]]
	assert_equal "$(cat "${COUNT}")" "x"
	run_tool deploy --answer nope=1
	assert_failure 1
	[[ "${stderr}" == *"nope"* ]]
	[[ "${stderr}" == *"confirmed"* ]]
	add_tool num 'r="$(mcp_elicit "How many?" "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"integer\"},\"s\":{\"type\":\"string\"}}}")"
printf "%s" "${r}" | jq -c "[.content.n, .content.s]"'
	run_tool num --answer '{"n":3}'
	assert_success
	assert_equal "$(result_text)" "[3,null]"
	run_tool num --answer n=3
	assert_success
	assert_equal "$(result_text)" "[3,null]"
	run_tool num --answer s=3
	assert_success
	assert_equal "$(result_text)" '[null,"3"]'
	run_tool num --answer n=three
	assert_failure 1
	[[ "${stderr}" == *"number"* ]]
}

@test "run_tool_answer: a URL question takes accept, decline or cancel" {
	add_tool login 'if mcp_elicit_url "Sign in" "https://example.com/login"; then echo in; else echo "no: ${MCP_ELICIT_ACTION}"; fi'
	run_tool login --answer accept
	assert_success
	assert_equal "$(result_text)" "in"
	run_tool login --answer x=1
	assert_failure 1
	[[ "${stderr}" == *"accept, decline or cancel"* ]]
}

@test "run_tool_answer: a tool that takes another path on the retry fails, it doesn't loop" {
	add_tool drift 'mcp_elicit_confirm "Question for attempt ${MCP_MRTR_ATTEMPT}" && echo yes || echo no'
	run_tool drift --answer true --answer true --answer true
	assert_failure 1
	assert_equal "$(printf '%s' "${output}" | jq -r '.isError')" "true"
	# The client is told only the position; run-tool shows what changed.
	[[ "${stderr}" == *"run 2: diverged: question 1 was "*"attempt 1"*"attempt 2"* ]]
}

@test "run_tool_answer: unused answers are reported; a tool that asks nothing prints no trace" {
	add_tool plain 'mcp_once bump p'
	run_tool plain --answer true
	assert_success
	assert_equal "$(result_text)" "p"
	[[ "${stderr}" == *"1 --answer value was not used"* ]]
	run_tool plain
	assert_success
	[[ "${stderr}" != *"run 1"* ]]
}

@test "run_tool_answer: --answer with no value is a usage error" {
	deploy_tool
	run_tool deploy --answer
	assert_failure
	[[ "${stderr}" == *"--answer"* ]]
	assert_equal "$(cat "${COUNT}")" ""
}

@test "run_tool_answer: --no-elicitation calls as a client that can't ask: questions are unavailable" {
	deploy_tool
	run_tool deploy --no-elicitation
	assert_success
	assert_equal "$(result_text)" "no: unavailable"
	[[ "${stderr}" != *"run 1"* ]]
	run_tool deploy --no-elicitation --answer true
	assert_failure
	[[ "${stderr}" == *"--no-elicitation"* ]]
}
