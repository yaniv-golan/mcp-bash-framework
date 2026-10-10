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
		timeout="$(mcp_json_extract_optional "${metadata_json}" -r '.timeoutSecs // 0' 0)"
		# Guard against empty/non-numeric values (fallback to 0)
		case "${timeout}" in ''|*[!0-9]*) timeout=0 ;; esac
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
assert_policy_denied "${deny_resp}" "disabled by policy" "read-only denial"

# Capability/auth gate with data payload
cat <<'REQ' >"${POLICY_ROOT}/requests-auth.ndjson"
{"jsonrpc":"2.0","id":"init-auth","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call-auth","method":"tools/call","params":{"name":"hello","arguments":{}}}
REQ
POLICY_REQUIRE_AUTH=1 POLICY_MAX_TIMEOUT=0 POLICY_READ_ONLY=0 \
	test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/requests-auth.ndjson" "${POLICY_ROOT}/responses-auth.ndjson"
auth_resp="$(grep '"id":"call-auth"' "${POLICY_ROOT}/responses-auth.ndjson" | head -n1)"
# The policy's own code (-32600) has no place in a tool result; its message
# and data still arrive.
assert_policy_denied "${auth_resp}" "Capability required" "auth gate"
auth_reason="$(echo "${auth_resp}" | jq -r '.result._meta["mcpbash/error"].data.reason // empty')"
test_assert_eq "auth" "${auth_reason}" "expected the policy's data to propagate"

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

# Invalidate cache to force re-discovery (slow tool was created after earlier tests cached tools.json)
test_invalidate_registry_cache "${POLICY_ROOT}"

cat <<'REQ' >"${POLICY_ROOT}/requests-timeout.ndjson"
{"jsonrpc":"2.0","id":"init-timeout","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call-timeout","method":"tools/call","params":{"name":"slow","arguments":{}}}
REQ
POLICY_MAX_TIMEOUT=10 POLICY_REQUIRE_AUTH=0 POLICY_READ_ONLY=0 \
	test_run_mcp "${POLICY_ROOT}" "${POLICY_ROOT}/requests-timeout.ndjson" "${POLICY_ROOT}/responses-timeout.ndjson"
timeout_resp="$(grep '"id":"call-timeout"' "${POLICY_ROOT}/responses-timeout.ndjson" | head -n1)"
assert_policy_denied "${timeout_resp}" "policy timeout" "timeout policy"
timeout_data="$(echo "${timeout_resp}" | jq -r '.result._meta["mcpbash/error"].data.timeout // empty')"
test_assert_eq "20" "${timeout_data}" "expected the policy's data to propagate"
