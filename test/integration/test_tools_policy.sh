#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="The project policy hook (mcp_tools_policy_project) restricts calls; the 1.x hook fails closed."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

POLICY_ROOT="${TEST_TMPDIR}/policy"
test_stage_workspace "${POLICY_ROOT}"

# Minimal tool we can block/allow via policy.
mkdir -p "${POLICY_ROOT}/tools/hello"
cat <<'META' >"${POLICY_ROOT}/tools/hello/tool.meta.json"
{
  "name": "hello",
  "description": "simple tool",
  "arguments": {
    "type": "object",
    "properties": {}
  },
  "outputSchema": {
    "type": "object",
    "properties": {"message": {"type": "string"}},
    "required": ["message"]
  }
}
META
cat <<'SH' >"${POLICY_ROOT}/tools/hello/tool.sh"
#!/usr/bin/env bash
printf '{"message":"hi"}'
SH
chmod +x "${POLICY_ROOT}/tools/hello/tool.sh"

cat <<'POLICY' >"${POLICY_ROOT}/server.d/policy.sh"
#!/usr/bin/env bash
set -euo pipefail

# 2.0 hook: $1 tool name, $2 call arguments (JSON). Runs after the built-in
# checks; non-zero denies, and stdout is the reason.
mcp_tools_policy_project() {
	local tool_name="$1" args_json="$2"
	if [ "${POLICY_READ_ONLY:-0}" = "1" ] && [ "${tool_name}" = "hello" ]; then
		printf "Tool '%s' disabled by policy" "${tool_name}"
		return 1
	fi
	case "${args_json}" in
	*danger*)
		printf 'Arguments refused by policy'
		return 1
		;;
	esac
	return 0
}
POLICY

req() {
	printf '%s\n' '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
	local args='{}'
	args="${1:-$args}"
	printf '{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"hello","arguments":%s}}\n' "${args}"
}
call() { grep '"id":"call"' "$1" | head -n1; }

# Policy denials are tool results with isError (type policy_denied), so clients
# show the reason; they are not JSON-RPC errors.
assert_policy_denied() {
	local resp="$1" want_msg="$2" label="$3"
	if ! echo "${resp}" | jq -e '(.error | not) and .result.isError == true and .result._meta["mcpbash/error"].type == "policy_denied"' >/dev/null; then
		test_fail "${label}: expected a policy_denied isError result, got: ${resp}"
	fi
	local text
	text="$(echo "${resp}" | jq -r '.result.content[0].text // empty')"
	if [[ "${text}" != *"${want_msg}"* ]]; then
		test_fail "${label}: expected message '${want_msg}', got: ${text}"
	fi
}

printf ' -> the hook allows\n'
req >"${POLICY_ROOT}/req.ndjson"
test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/req.ndjson" "${POLICY_ROOT}/allow.ndjson"
test_assert_eq "hi" "$(call "${POLICY_ROOT}/allow.ndjson" | jq -r '.result.structuredContent.message // empty')"
# No top-level "name" on a tool result (not in the MCP schema; gone in 2.0).
call "${POLICY_ROOT}/allow.ndjson" | jq -e '.result | has("name") | not' >/dev/null || test_fail "tool result still has a top-level name"

printf ' -> the hook denies by name, with its reason\n'
POLICY_READ_ONLY=1 test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/req.ndjson" "${POLICY_ROOT}/deny.ndjson"
assert_policy_denied "$(call "${POLICY_ROOT}/deny.ndjson")" "disabled by policy" "read-only denial"

printf ' -> the hook denies by the call arguments ($2)\n'
req '{"mode":"danger"}' >"${POLICY_ROOT}/req-args.ndjson"
test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/req-args.ndjson" "${POLICY_ROOT}/deny-args.ndjson"
assert_policy_denied "$(call "${POLICY_ROOT}/deny-args.ndjson")" "Arguments refused by policy" "argument denial"

printf ' -> the hook can only restrict: the operator allowlist still applies\n'
MCPBASH_TOOL_ALLOWLIST="other" test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/req.ndjson" "${POLICY_ROOT}/allowlist.ndjson"
assert_policy_denied "$(call "${POLICY_ROOT}/allowlist.ndjson")" "not in MCPBASH_TOOL_ALLOWLIST" "allowlist before the hook"

# A policy.sh that can't be loaded refuses every call (fail closed): the
# client gets a policy_denied result naming the reason, never no answer.
broken_policy() {
	local label="$1" want="$2"
	test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/req.ndjson" "${POLICY_ROOT}/broken-${label}.ndjson"
	local r
	r="$(call "${POLICY_ROOT}/broken-${label}.ndjson")"
	[ -n "${r}" ] || test_fail "${label}: no response to tools/call"
	assert_policy_denied "${r}" "${want}" "${label}"
	case "$(jq -r 'select(.id=="init") | .result.instructions // ""' "${POLICY_ROOT}/broken-${label}.ndjson")" in
	*"server.d/policy.sh) can't be loaded, so every tool call is refused"*) ;;
	*) test_fail "${label}: no instructions sentence" ;;
	esac
}
DENY_SECRET='mcp_tools_policy_project() { [ "$1" != hello ] || { printf "hello is off"; return 1; }; }'

printf ' -> policy.sh writable by others: not loaded, every call refused\n'
printf '%s\n' "${DENY_SECRET}" >"${POLICY_ROOT}/server.d/policy.sh"
chmod 0666 "${POLICY_ROOT}/server.d/policy.sh"
broken_policy perms "Tool calls are refused: server.d/policy.sh was not loaded: it, server.d or the project root is writable"
chmod 0644 "${POLICY_ROOT}/server.d/policy.sh"

printf ' -> policy.sh with a syntax error: every call refused, with an answer\n'
printf '%s\n' "${DENY_SECRET}" 'if then' >"${POLICY_ROOT}/server.d/policy.sh"
broken_policy syntax "was not loaded: it has a syntax error"

printf ' -> policy.sh that exits at the top level: every call refused, with an answer\n'
printf '%s\n' "${DENY_SECRET}" 'exit 0' >"${POLICY_ROOT}/server.d/policy.sh"
broken_policy exit "was not loaded: it stops while loading"

printf ' -> a plain failing top-level command: every call refused, with an answer\n'
printf '%s\n' "${DENY_SECRET}" 'false' >"${POLICY_ROOT}/server.d/policy.sh"
broken_policy false "was not loaded: it stops while loading"

printf ' -> a syntax error in a file policy.sh sources: every call refused\n'
printf '%s\n' 'if then' >"${POLICY_ROOT}/server.d/policy-lib.sh"
printf '%s\n' '. "${MCPBASH_SERVER_DIR}/policy-lib.sh"' "${DENY_SECRET}" >"${POLICY_ROOT}/server.d/policy.sh"
broken_policy nested "was not loaded: it stops while loading"
rm -f "${POLICY_ROOT}/server.d/policy-lib.sh"

printf ' -> a last command that fails is fine: the hook still applies\n'
printf '%s\n' "${DENY_SECRET}" '[ -n "${NOT_SET_ANYWHERE:-}" ] && export X=1' >"${POLICY_ROOT}/server.d/policy.sh"
test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/req.ndjson" "${POLICY_ROOT}/lastfail.ndjson"
assert_policy_denied "$(call "${POLICY_ROOT}/lastfail.ndjson")" "hello is off" "last command fails"

printf ' -> the load probe runs once per version of policy.sh, not per start\n'
COUNT="${TEST_TMPDIR}/policy-runs"
: >"${COUNT}"
printf '%s\n' "printf x >>'${COUNT}'" "${DENY_SECRET}" >"${POLICY_ROOT}/server.d/policy.sh"
rm -rf "${POLICY_ROOT}/.registry/scan/policy.loads"
test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/req.ndjson" "${POLICY_ROOT}/probe1.ndjson"
first="$(wc -c <"${COUNT}" | tr -d ' ')"
test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/req.ndjson" "${POLICY_ROOT}/probe2.ndjson"
total="$(wc -c <"${COUNT}" | tr -d ' ')"
second=$((total - first))
# First start: the probe and the call's worker; second start: the worker only.
test_assert_eq "${first}" "2"
test_assert_eq "${second}" "1"
assert_policy_denied "$(call "${POLICY_ROOT}/probe2.ndjson")" "hello is off" "cached verdict"

printf ' -> policy.sh cannot redefine the built-in checks\n'
printf '%s\n' 'mcp_tools_policy_enforce() { return 0; }' 'mcp_tools_policy_check_default() { return 0; }' >"${POLICY_ROOT}/server.d/policy.sh"
MCPBASH_TOOL_ALLOWLIST="other" test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/req.ndjson" "${POLICY_ROOT}/redefine.ndjson"
assert_policy_denied "$(call "${POLICY_ROOT}/redefine.ndjson")" "not in MCPBASH_TOOL_ALLOWLIST" "redefined built-ins"

printf ' -> the 1.x hook (mcp_tools_policy_check) fails closed\n'
cat <<'POLICY' >"${POLICY_ROOT}/server.d/policy.sh"
#!/usr/bin/env bash
mcp_tools_policy_check() {
	mcp_tools_policy_check_default "$@" || return 1
	return 0
}
POLICY
test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/req.ndjson" "${POLICY_ROOT}/legacy.ndjson"
r="$(call "${POLICY_ROOT}/legacy.ndjson" | jq -c '.result')"
assert_eq '[true,"migration_required","mcp_tools_policy_check"]' "$(printf '%s' "${r}" | jq -c '[.isError, ._meta["mcpbash/error"].type, ._meta["mcpbash/error"].data.removed]')" "legacy hook: ${r}"
case "$(printf '%s' "${r}" | jq -r '.content[0].text')" in
*'rename the function to mcp_tools_policy_project'*'read the call arguments from $2'*) ;;
*) test_fail "legacy hook: the text doesn't say what to change: ${r}" ;;
esac
case "$(jq -r 'select(.id=="init") | .result.instructions // ""' "${POLICY_ROOT}/legacy.ndjson")" in
*"uses the mcp-bash 1.x hook, so every tool call is refused"*) ;;
*) test_fail "legacy hook: no instructions sentence" ;;
esac

printf ' -> migrate --write renames a hook it can prove safe; then calls work\n'
(cd "${POLICY_ROOT}" && ./bin/mcp-bash migrate --project-root "${POLICY_ROOT}" --write --only 2-policy-replace --force >/dev/null 2>&1) || true
grep -q '^mcp_tools_policy_project()' "${POLICY_ROOT}/server.d/policy.sh" || test_fail "migrate did not rename the hook: $(cat "${POLICY_ROOT}/server.d/policy.sh")"
test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/req.ndjson" "${POLICY_ROOT}/migrated.ndjson"
test_assert_eq "hi" "$(call "${POLICY_ROOT}/migrated.ndjson" | jq -r '.result.structuredContent.message // empty')"
if jq -r 'select(.id=="init") | .result.instructions // ""' "${POLICY_ROOT}/migrated.ndjson" | grep -q '1.x hook'; then
	test_fail "migrated: instructions still mention the 1.x hook"
fi

printf 'Tool policy tests passed.\n'
