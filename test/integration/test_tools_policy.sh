#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Tool policy hook enforces server.d/policy.sh before execution."
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

mcp_tools_policy_check() {
	local tool_name="$1"
	local metadata_json="$2"
	if [ "${POLICY_READ_ONLY:-0}" = "1" ] && [ "${tool_name}" = "hello" ]; then
		mcp_tools_error -32602 "Tool '${tool_name}' disabled by policy"
		return 1
	fi
	# Capability gate example with data payload
	if [ "${POLICY_REQUIRE_AUTH:-0}" = "1" ] && [ "${tool_name}" = "hello" ]; then
		mcp_tools_error -32600 "Capability required" '{"reason":"auth"}'
		return 1
	fi
	# Metadata-driven denial: block tools whose timeout exceeds 10s
	if [ "${POLICY_MAX_TIMEOUT:-0}" != "0" ]; then
		local timeout
		timeout="$(printf '%s' "${metadata_json}" | jq -r '.timeoutSecs // 0')"
		if [ "${timeout}" -gt "${POLICY_MAX_TIMEOUT}" ]; then
			mcp_tools_error -32602 "Tool '${tool_name}' exceeds policy timeout" "{\"timeout\":${timeout}}"
			return 1
		fi
	fi
	return 0
}
POLICY

# Allow path (read-only off)
cat <<'REQ' >"${POLICY_ROOT}/requests-allow.ndjson"
{"jsonrpc":"2.0","id":"init-allow","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call-allow","method":"tools/call","params":{"name":"hello","arguments":{}}}
REQ
test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/requests-allow.ndjson" "${POLICY_ROOT}/responses-allow.ndjson"
allow_resp="$(grep '"id":"call-allow"' "${POLICY_ROOT}/responses-allow.ndjson" | head -n1)"
message="$(echo "${allow_resp}" | jq -r '.result.structuredContent.message // empty')"
test_assert_eq "hi" "${message}"

# Deny path (read-only on)
cat <<'REQ' >"${POLICY_ROOT}/requests-deny.ndjson"
{"jsonrpc":"2.0","id":"init-deny","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call-deny","method":"tools/call","params":{"name":"hello","arguments":{}}}
REQ
POLICY_READ_ONLY=1 test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/requests-deny.ndjson" "${POLICY_ROOT}/responses-deny.ndjson"
deny_resp="$(grep '"id":"call-deny"' "${POLICY_ROOT}/responses-deny.ndjson" | head -n1)"
deny_code="$(echo "${deny_resp}" | jq -r '.error.code // empty')"
deny_msg="$(echo "${deny_resp}" | jq -r '.error.message // empty')"

test_assert_eq "-32602" "${deny_code}" "expected policy violation to surface as -32602"
if [[ "${deny_msg}" != *"disabled by policy"* ]]; then
	test_fail "expected policy message, got: ${deny_msg}"
fi

# Capability/auth gate with data payload
cat <<'REQ' >"${POLICY_ROOT}/requests-auth.ndjson"
{"jsonrpc":"2.0","id":"init-auth","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call-auth","method":"tools/call","params":{"name":"hello","arguments":{}}}
REQ
POLICY_REQUIRE_AUTH=1 POLICY_MAX_TIMEOUT=0 POLICY_READ_ONLY=0 \
	test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/requests-auth.ndjson" "${POLICY_ROOT}/responses-auth.ndjson"
auth_resp="$(grep '"id":"call-auth"' "${POLICY_ROOT}/responses-auth.ndjson" | head -n1)"
auth_code="$(echo "${auth_resp}" | jq -r '.error.code // empty')"
auth_msg="$(echo "${auth_resp}" | jq -r '.error.message // empty')"
auth_reason="$(echo "${auth_resp}" | jq -r '.error.data.reason // empty')"
test_assert_eq "-32600" "${auth_code}" "expected capability/auth gate to surface as -32600"
if [[ "${auth_msg}" != *"Capability required"* ]]; then
	test_fail "expected auth message, got: ${auth_msg}"
fi
test_assert_eq "auth" "${auth_reason}" "expected error.data.reason to propagate"

# Metadata-driven denial (timeout)
mkdir -p "${POLICY_ROOT}/tools/slow"
cat <<'META' >"${POLICY_ROOT}/tools/slow/tool.meta.json"
{
  "name": "slow",
  "description": "slow tool",
  "path": "slow/tool.sh",
  "timeoutSecs": 20,
  "arguments": {"type": "object", "properties": {}},
  "outputSchema": {"type": "object", "properties": {"ok": {"type": "boolean"}}}
}
META
cat <<'SH' >"${POLICY_ROOT}/tools/slow/tool.sh"
#!/usr/bin/env bash
printf '{"ok":true}'
SH
chmod +x "${POLICY_ROOT}/tools/slow/tool.sh"

cat <<'REQ' >"${POLICY_ROOT}/requests-timeout.ndjson"
{"jsonrpc":"2.0","id":"init-timeout","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call-timeout","method":"tools/call","params":{"name":"slow","arguments":{}}}
REQ
POLICY_MAX_TIMEOUT=10 POLICY_REQUIRE_AUTH=0 POLICY_READ_ONLY=0 \
	test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/requests-timeout.ndjson" "${POLICY_ROOT}/responses-timeout.ndjson"
timeout_resp="$(grep '"id":"call-timeout"' "${POLICY_ROOT}/responses-timeout.ndjson" | head -n1)"
timeout_code="$(echo "${timeout_resp}" | jq -r '.error.code // empty')"
timeout_msg="$(echo "${timeout_resp}" | jq -r '.error.message // empty')"
timeout_data="$(echo "${timeout_resp}" | jq -r '.error.data.timeout // empty')"
test_assert_eq "-32602" "${timeout_code}" "expected timeout policy to surface as -32602"
if [[ "${timeout_msg}" != *"policy timeout"* ]]; then
	test_fail "expected timeout policy message, got: ${timeout_msg}"
fi
test_assert_eq "20" "${timeout_data}" "expected error.data.timeout to propagate"
