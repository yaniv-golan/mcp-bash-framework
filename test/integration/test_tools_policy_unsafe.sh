#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="A server.d/policy.sh that can't be loaded safely refuses every tool call."
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

# A policy.sh the server refuses to source (group-writable, or a syntax error)
# used to be skipped: the operator allowlist still applied, but the project's
# own restrictions (a read-only mode, say) were silently dropped, and with a
# syntax error bash 3.2 stopped the worker, so the call got no response.

WS="${TEST_TMPDIR}/ws"
test_stage_workspace "${WS}"
chmod go-w "${WS}"
mkdir -p "${WS}/server.d" "${WS}/tools/write"
chmod 755 "${WS}/server.d"
printf '%s\n' '{"name": "policy-unsafe"}' >"${WS}/server.d/server.meta.json"
printf '%s\n' '{"name":"write","description":"w","inputSchema":{"type":"object"}}' >"${WS}/tools/write/tool.meta.json"
printf '#!/usr/bin/env bash\necho WROTE\n' >"${WS}/tools/write/tool.sh"
chmod +x "${WS}/tools/write/tool.sh"

POLICY="${WS}/server.d/policy.sh"
deny_all_policy() {
	cat >"${POLICY}" <<'EOF'
mcp_tools_policy_project() {
	printf 'read-only mode: %s is blocked' "$1"
	return 1
}
EOF
}

call_write() {
	local out="$1"
	cat >"${TEST_TMPDIR}/requests.ndjson" <<'JSON'
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"write","arguments":{}}}
JSON
	MCPBASH_TOOL_ALLOWLIST='write' test_run_mcp "${WS}" "${TEST_TMPDIR}/requests.ndjson" "${out}"
}

result_of() {
	jq -c 'select(.id=="call") | {isError: .result.isError, text: .result.content[0].text}' "$1"
}

# Safe policy.sh: the project hook denies.
deny_all_policy
chmod 644 "${POLICY}"
out="${TEST_TMPDIR}/safe.ndjson"
call_write "${out}"
assert_eq '{"isError":true,"text":"read-only mode: write is blocked"}' "$(result_of "${out}")" "safe policy.sh"

# Group-writable policy.sh: refused, and so is the call.
chmod 664 "${POLICY}"
out="${TEST_TMPDIR}/groupw.ndjson"
call_write "${out}"
r="$(result_of "${out}")"
assert_eq "true" "$(printf '%s' "${r}" | jq -r '.isError')" "group-writable policy.sh: the call must be refused: ${r}"
case "${r}" in
*"server.d/policy.sh"*"group or other users"*) ;;
*) test_fail "group-writable policy.sh: the message should name the file and the reason: ${r}" ;;
esac
grep -q 'policy.sh' "${out}.stderr" || test_fail "group-writable policy.sh: nothing on stderr: $(cat "${out}.stderr")"
if grep -q 'WROTE' "${out}"; then
	test_fail "group-writable policy.sh: the tool ran"
fi

# Syntax error: refused, with a response.
printf 'mcp_tools_policy_project() {\n\tprintf no\n' >"${POLICY}"
chmod 644 "${POLICY}"
out="${TEST_TMPDIR}/syntax.ndjson"
call_write "${out}"
r="$(result_of "${out}")"
[ -n "${r}" ] || test_fail "syntax error in policy.sh: no response to the call: $(cat "${out}")"
assert_eq "true" "$(printf '%s' "${r}" | jq -r '.isError')" "syntax error in policy.sh: the call must be refused: ${r}"
case "${r}" in
*"syntax"*) ;;
*) test_fail "syntax error in policy.sh: the message should say so: ${r}" ;;
esac

# A policy.sh that dies while it is sourced refuses every call too: the call
# gets a refusal, never no answer, and the blocked tool never runs.
SD="${WS}/server.d"
DENY_HOOK='mcp_tools_policy_project() { printf "read-only mode: %s is blocked" "$1"; return 1; }'
DENY_CHECK='mcp_tools_policy_check() { _MCP_TOOLS_ERROR_CODE=-32602; _MCP_TOOLS_ERROR_MESSAGE="replaced check: $1 is blocked"; return 1; }'

refused() {
	local label="$1" want="$2" out="${TEST_TMPDIR}/$1.ndjson"
	call_write "${out}"
	local r
	r="$(result_of "${out}")"
	[ -n "${r}" ] || test_fail "${label}: no response to the call: $(cat "${out}")"
	assert_eq "true" "$(printf '%s' "${r}" | jq -r '.isError')" "${label}: the call must be refused: ${r}"
	case "${r}" in
	*"${want}"*) ;;
	*) test_fail "${label}: expected '${want}' in: ${r}" ;;
	esac
	if grep -q 'WROTE' "${out}"; then
		test_fail "${label}: the tool ran"
	fi
}

write_policy() {
	printf '%s\n' "$@" >"${POLICY}"
	chmod 644 "${POLICY}"
}

write_policy "${DENY_HOOK}" 'exit 0'
refused exit "was not loaded: it stops while loading"
test_assert_eq "$(grep -c 'was not loaded' "${TEST_TMPDIR}/exit.ndjson.stderr")" "1"

write_policy "${DENY_HOOK}" 'false'
refused false "was not loaded: it stops while loading"

printf '%s\n' 'if then' >"${SD}/policy-lib.sh"
write_policy '. "${MCPBASH_SERVER_DIR}/policy-lib.sh"' "${DENY_HOOK}"
refused nested "was not loaded: it stops while loading"
rm -f "${SD}/policy-lib.sh"

# The server paths are there at the top level, as in a worker.
printf '%s\n' "${DENY_HOOK}" >"${SD}/rules.sh"
write_policy 'set -u' ': "${MCPBASH_HOME}" "${MCPBASH_TOOLS_DIR}" "${MCPBASH_STATE_DIR}" "${MCPBASH_PROJECT_ROOT}"' '. "${MCPBASH_SERVER_DIR}/rules.sh"'
refused paths "read-only mode: write is blocked"
rm -f "${SD}/rules.sh"

# A last command that fails is fine: the hook still applies.
write_policy "${DENY_HOOK}" '[ -n "${NOT_SET_ANYWHERE:-}" ] && export X=1'
refused lastfail "read-only mode: write is blocked"

# A sourced file that breaks after the start check (here it replaces itself
# with a broken copy when sourced): the hook the start check saw is gone,
# so calls are refused. Bash 3.2 ends the worker on the syntax error in the
# sourced file instead: no answer, and the tool still doesn't run.
late_break() {
	local label="$1" hook="$2"
	printf '%s\n' 'if then' "${hook}" >"${SD}/rules-broken.sh"
	printf '%s\n' "${hook}" 'cp "${MCPBASH_SERVER_DIR}/rules-broken.sh" "${MCPBASH_SERVER_DIR}/rules.sh"' >"${SD}/rules.sh"
	write_policy '. "${MCPBASH_SERVER_DIR}/rules.sh"'
	local out="${TEST_TMPDIR}/${label}.ndjson"
	call_write "${out}"
	local r
	r="$(result_of "${out}")"
	if grep -q 'WROTE' "${out}"; then
		test_fail "${label}: the tool ran: ${r}"
	fi
	if [ -n "${r}" ] || [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
		assert_eq "true" "$(printf '%s' "${r}" | jq -r '.isError')" "${label}: the call must be refused: ${r}"
		case "${r}" in
		*"was not loaded"*) ;;
		*) test_fail "${label}: expected 'was not loaded' in: ${r}" ;;
		esac
	fi
	rm -f "${SD}/rules.sh" "${SD}/rules-broken.sh"
}
late_break late-hook "${DENY_HOOK}"
late_break late-check "${DENY_CHECK}"

# The load check runs once per start, then once per call's worker.
COUNT="${TEST_TMPDIR}/policy-runs"
: >"${COUNT}"
write_policy "printf x >>'${COUNT}'" "${DENY_HOOK}"
refused count "read-only mode: write is blocked"
test_assert_eq "$(wc -c <"${COUNT}" | tr -d ' ')" "2"

printf 'Unsafe policy.sh test passed.\n'
