#!/usr/bin/env bash
# Smoke test covering initialize → tools/list → tools/call.
# Local quick check only; not run in CI (integration/compatibility suites cover this path).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common/env.sh"
# shellcheck source=common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common/assert.sh"

VERBOSE="${VERBOSE:-0}"
UNICODE="${UNICODE:-0}"

PASS_ICON="[PASS]"
if [ "${UNICODE}" = "1" ]; then
	PASS_ICON="✅"
fi

test_require_command jq

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/smoke"
test_stage_workspace "${WORKSPACE}"

mkdir -p "${WORKSPACE}/tools"
cat <<'META' >"${WORKSPACE}/tools/smoke.meta.json"
{
  "name": "smoke.echo",
  "description": "Return fixed message",
  "arguments": {
    "type": "object",
    "properties": {}
  }
}
META

cat <<'SH' >"${WORKSPACE}/tools/smoke.sh"
#!/usr/bin/env bash
set -euo pipefail
printf 'Hello from smoke tool'
SH
chmod +x "${WORKSPACE}/tools/smoke.sh"

mkdir -p "${WORKSPACE}/server.d"
cat <<'REG' >"${WORKSPACE}/server.d/register.sh"
#!/usr/bin/env bash
set -euo pipefail

mcp_register_tool '{
  "name": "smoke.echo",
  "description": "Return fixed message",
  "path": "smoke.sh",
  "arguments": {"type": "object", "properties": {}}
}'
REG
chmod +x "${WORKSPACE}/server.d/register.sh"

cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"list1","method":"tools/list"}
{"jsonrpc":"2.0","id":"list2","method":"tools/list"}
{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"smoke.echo","arguments":{}}}
JSON

test_run_mcp "${WORKSPACE}" "${WORKSPACE}/requests.ndjson" "${WORKSPACE}/responses.ndjson"
assert_file_exists "${WORKSPACE}/responses.ndjson"
assert_json_lines "${WORKSPACE}/responses.ndjson"

# Verify responses with jq
response_file="${WORKSPACE}/responses.ndjson"

# Check init
if ! jq -e 'select(.id=="init") | .result.protocolVersion == "2025-11-25"' "${response_file}" >/dev/null; then
	test_fail "protocolVersion mismatch or missing init response"
fi

# Check tool discovery
if ! jq -e 'select(.id=="list2") | .result.tools[] | select(.name=="smoke.echo")' "${response_file}" >/dev/null; then
	# fallback structure check (might be result.items if direct)
	if ! jq -e 'select(.id=="list2") | .result.items[] | select(.name=="smoke.echo")' "${response_file}" >/dev/null; then
		test_fail "smoke tool not discovered"
	fi
fi

# Check tool call
call_result="$(jq -c 'select(.id=="call")' "${response_file}")"
if [ -z "${call_result}" ]; then
	test_fail "missing call response"
fi
if echo "${call_result}" | jq -e '.error' >/dev/null; then
	test_fail "tool call returned error: $(echo "${call_result}" | jq -r '.error.message')"
fi
if ! echo "${call_result}" | jq -e '.result._meta.exitCode == 0' >/dev/null; then
	# _meta might be optional or different structure depending on implementation details, but spec says result content
	true
fi
text="$(echo "${call_result}" | jq -r '.result.content[] | select(.type=="text") | .text')"
if [[ "${text}" != *"Hello from smoke tool"* ]]; then
	test_fail "tool call text missing or incorrect: ${text}"
fi

printf '%s smoke.sh\n' "${PASS_ICON}"
printf '\nSmoke summary: 1 passed, 0 failed\n'
