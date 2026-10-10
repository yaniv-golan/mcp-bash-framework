#!/usr/bin/env bash
# Integration: policy denials are isError tool results; the project hook
# mcp_tools_policy_project restricts calls and supplies the denial message.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Policy denials as policy_denied tool results; mcp_tools_policy_project hook."

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
WORKSPACE="${TEST_TMPDIR}/denied"
test_stage_workspace "${WORKSPACE}"
mkdir -p "${WORKSPACE}/tools/hello"
cp "${MCPBASH_HOME}/examples/00-hello-tool/tools/hello/"* "${WORKSPACE}/tools/hello/"
TOOL="example-hello"

cat <<JSON >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"${TOOL}","arguments":{"mode":"MODE"}}}
JSON

# Run one tools/call with the given call mode; leave the response line in RESP.
call_tool() {
	local mode="$1"
	sed "s/MODE/${mode}/" "${WORKSPACE}/requests.ndjson" >"${WORKSPACE}/req.${mode}.ndjson"
	test_run_mcp "${WORKSPACE}" "${WORKSPACE}/req.${mode}.ndjson" "${WORKSPACE}/resp.${mode}.ndjson"
	# Every line on stdout must be a JSON-RPC message: a hook that prints must
	# never reach the protocol stream.
	assert_json_lines "${WORKSPACE}/resp.${mode}.ndjson"
	RESP="$(jq -c 'select(.id == "call")' "${WORKSPACE}/resp.${mode}.ndjson")"
}

expect_denied() {
	local label="$1" want_text="$2"
	if ! printf '%s' "${RESP}" | jq -e '(.error | not) and .result.isError == true and .result._meta["mcpbash/error"].type == "policy_denied" and (.result | has("structuredContent") | not)' >/dev/null; then
		test_fail "${label}: expected a policy_denied isError result, got: ${RESP}"
	fi
	local text
	text="$(printf '%s' "${RESP}" | jq -r '.result.content[0].text')"
	if [ "${text}" != "${want_text}" ]; then
		test_fail "${label}: text mismatch: got '${text}', want '${want_text}'"
	fi
}

expect_allowed() {
	local label="$1"
	if ! printf '%s' "${RESP}" | jq -e '(.error | not) and .result.isError == false' >/dev/null; then
		test_fail "${label}: expected the tool to run, got: ${RESP}"
	fi
}

# (a) Default deny: no allowlist.
unset MCPBASH_TOOL_ALLOWLIST MCPBASH_TOOL_ALLOW_DEFAULT
call_tool none
expect_denied "allowlist" "Tool '${TOOL}' blocked by policy. Set MCPBASH_TOOL_ALLOWLIST in your MCP client config."

# (c) Restrict-only project hook. The default allowlist still applies first.
cat <<'SH' >"${WORKSPACE}/server.d/policy.sh"
mcp_tools_policy_project() {
	local tool="$1" args="$2" mode
	mode="$(printf '%s' "${args}" | jq -r '.mode // ""')"
	case "${mode}" in
	allow-noisy)
		# Output on allow is discarded, never sent to the client.
		printf 'noise that must not reach stdout\n'
		return 0
		;;
	deny)
		printf 'Writes are disabled for %s.\nAsk the user to turn off read-only mode.\n' "${tool}"
		return 1
		;;
	deny-empty) return 3 ;;
	deny-long)
		head -c 3000 /dev/zero | tr '\0' 'x'
		return 1
		;;
	esac
	return 0
}
SH
chmod 0644 "${WORKSPACE}/server.d/policy.sh"
export MCPBASH_TOOL_ALLOWLIST="${TOOL}"

call_tool allow-noisy
expect_allowed "hook allow"
if grep -q 'noise that must not reach stdout' "${WORKSPACE}/resp.allow-noisy.ndjson"; then
	test_fail "hook output on allow reached the protocol stream"
fi

call_tool deny
expect_denied "hook deny" "Writes are disabled for ${TOOL}.
Ask the user to turn off read-only mode."

call_tool deny-empty
expect_denied "hook deny, no message" "Tool '${TOOL}' denied by server policy"

call_tool deny-long
long_len="$(printf '%s' "${RESP}" | jq -r '.result.content[0].text | length')"
test_assert_eq "1024" "${long_len}"

# The allowlist is checked before the hook.
MCPBASH_TOOL_ALLOWLIST="other-tool" call_tool deny
expect_denied "allowlist before hook" "Tool '${TOOL}' blocked by policy (not in MCPBASH_TOOL_ALLOWLIST)"

# (e) run-tool prints the denial and exits non-zero.
set +e
run_out="$(cd "${WORKSPACE}" && MCPBASH_PROJECT_ROOT="${WORKSPACE}" ./bin/mcp-bash run-tool "${TOOL}" --args '{"mode":"deny"}' 2>/dev/null)"
run_rc=$?
set -e
if [ "${run_rc}" -eq 0 ]; then
	test_fail "run-tool exited 0 on a policy denial"
fi
if ! printf '%s' "${run_out}" | jq -e '.isError == true and ._meta["mcpbash/error"].type == "policy_denied"' >/dev/null; then
	test_fail "run-tool did not print the policy_denied result: ${run_out}"
fi
case "${run_out}" in
*"Writes are disabled"*) ;;
*) test_fail "run-tool output lacks the denial message: ${run_out}" ;;
esac

printf 'Policy denial test passed.\n'
