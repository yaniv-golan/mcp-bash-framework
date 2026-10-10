#!/usr/bin/env bash
# Integration: early tools/call refusals reach the client with their own code and message.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Inherit gate, rejected path and missing executable report specific errors."

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
WORKSPACE="${TEST_TMPDIR}/tool-refusals"
test_stage_workspace "${WORKSPACE}"
mkdir -p "${WORKSPACE}/tools/manual"

# A runnable tool, a group/world-writable tool (rejected by path policy), and a
# plain data file with no shebang and no exec bit (not executable).
cat <<'SH' >"${WORKSPACE}/tools/manual/ok.sh"
#!/usr/bin/env bash
printf 'ok'
SH
chmod 0755 "${WORKSPACE}/tools/manual/ok.sh"
cat <<'SH' >"${WORKSPACE}/tools/manual/writable.sh"
#!/usr/bin/env bash
printf 'should not run'
SH
chmod 0777 "${WORKSPACE}/tools/manual/writable.sh"
printf 'just data\n' >"${WORKSPACE}/tools/manual/data"
chmod 0644 "${WORKSPACE}/tools/manual/data"

cat <<'SCRIPT' >"${WORKSPACE}/server.d/register.sh"
#!/usr/bin/env bash
set -euo pipefail
mcp_register_tool '{"name":"ok-tool","description":"ok","path":"manual/ok.sh","arguments":{"type":"object","properties":{}}}'
mcp_register_tool '{"name":"writable-tool","description":"writable","path":"manual/writable.sh","arguments":{"type":"object","properties":{}}}'
mcp_register_tool '{"name":"data-tool","description":"data","path":"manual/data","arguments":{"type":"object","properties":{}}}'
return 0
SCRIPT
chmod 0755 "${WORKSPACE}/server.d/register.sh"

cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"ok","method":"tools/call","params":{"name":"ok-tool","arguments":{}}}
{"jsonrpc":"2.0","id":"writable","method":"tools/call","params":{"name":"writable-tool","arguments":{}}}
{"jsonrpc":"2.0","id":"data","method":"tools/call","params":{"name":"data-tool","arguments":{}}}
JSON

# expect_error <responses> <id> <code> <message-substring>
expect_error() {
	local responses="$1" id="$2" want_code="$3" want_msg="$4"
	local resp code msg
	resp="$(jq -c --arg id "${id}" 'select(.id==$id)' "${responses}")"
	[ -n "${resp}" ] || test_fail "missing response for id=${id}"
	code="$(printf '%s' "${resp}" | jq -r '.error.code // empty')"
	msg="$(printf '%s' "${resp}" | jq -r '.error.message // empty')"
	if [ "${code}" != "${want_code}" ]; then
		test_fail "id=${id}: expected code ${want_code}, got '${code}' (${msg})"
	fi
	case "${msg}" in
	*"${want_msg}"*) ;;
	*) test_fail "id=${id}: expected message containing '${want_msg}', got '${msg}'" ;;
	esac
	# Messages must never carry absolute paths.
	case "${msg}" in
	*"${WORKSPACE}"* | *"/tools/"*) test_fail "id=${id}: message leaks a path: ${msg}" ;;
	esac
}

# Default (minimal) env: path policy and missing executable.
RESPONSES="${WORKSPACE}/responses.ndjson"
test_run_mcp "${WORKSPACE}" "${WORKSPACE}/requests.ndjson" "${RESPONSES}"
assert_json_lines "${RESPONSES}"
ok_text="$(jq -r 'select(.id=="ok") | .result.content[0].text // empty' "${RESPONSES}")"
test_assert_eq "${ok_text}" "ok"
# The default policy check already refuses this path (its own message).
expect_error "${RESPONSES}" "writable" "-32602" "path rejected by policy"
expect_error "${RESPONSES}" "data" "-32602" "Tool executable missing"

# A project policy.sh that allows everything skips the default path check, so
# the call-time path validation in mcp_tools_call is what refuses it.
cat <<'SH' >"${WORKSPACE}/server.d/policy.sh"
mcp_tools_policy_check() {
	return 0
}
SH
chmod 0644 "${WORKSPACE}/server.d/policy.sh"
RESPONSES_POLICY="${WORKSPACE}/responses-policy.ndjson"
test_run_mcp "${WORKSPACE}" "${WORKSPACE}/requests.ndjson" "${RESPONSES_POLICY}"
assert_json_lines "${RESPONSES_POLICY}"
expect_error "${RESPONSES_POLICY}" "writable" "-32602" "Tool path rejected by policy"
expect_error "${RESPONSES_POLICY}" "data" "-32602" "Tool executable missing"
rm -f "${WORKSPACE}/server.d/policy.sh"

# Inherit mode without the operator's INHERIT_ALLOW: refused with the gate's text.
RESPONSES_INHERIT="${WORKSPACE}/responses-inherit.ndjson"
MCPBASH_TOOL_ENV_MODE=inherit MCPBASH_TOOL_ENV_INHERIT_ALLOW="" \
	test_run_mcp "${WORKSPACE}" "${WORKSPACE}/requests.ndjson" "${RESPONSES_INHERIT}"
assert_json_lines "${RESPONSES_INHERIT}"
expect_error "${RESPONSES_INHERIT}" "ok" "-32602" "MCPBASH_TOOL_ENV_INHERIT_ALLOW=true"

printf 'Tool refusal error tests passed.\n'
