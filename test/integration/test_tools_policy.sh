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
	if [ "${POLICY_READ_ONLY:-0}" = "1" ] && [ "${tool_name}" = "hello" ]; then
		mcp_tools_error -32602 "Tool '${tool_name}' disabled by policy"
		return 1
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
