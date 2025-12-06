#!/usr/bin/env bash
# Integration: tool error propagation, stderr capture, timeout overrides.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Tool stderr, non-zero exit, and timeouts."

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
WORKSPACE="${TEST_TMPDIR}/tool-errors"
test_stage_workspace "${WORKSPACE}"

mkdir -p "${WORKSPACE}/tools/fail"

# Tool exits non-zero and prints stderr
cat <<'META' >"${WORKSPACE}/tools/fail/tool.meta.json"
{"name":"fail.tool","description":"fail","arguments":{"type":"object","properties":{}}}
META
cat <<'SH' >"${WORKSPACE}/tools/fail/tool.sh"
#!/usr/bin/env bash
echo "nope" >&2
exit 7
SH
chmod +x "${WORKSPACE}/tools/fail/tool.sh"

# Tool with metadata timeout overridden by request
mkdir -p "${WORKSPACE}/tools/slow"
cat <<'META' >"${WORKSPACE}/tools/slow/tool.meta.json"
{"name":"slow.tool","description":"slow","arguments":{"type":"object","properties":{}},"timeoutSecs":5}
META
cat <<'SH' >"${WORKSPACE}/tools/slow/tool.sh"
#!/usr/bin/env bash
sleep 3
echo "should-timeout"
SH
chmod +x "${WORKSPACE}/tools/slow/tool.sh"

cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"fail","method":"tools/call","params":{"name":"fail.tool","arguments":{}}}
{"jsonrpc":"2.0","id":"slow","method":"tools/call","params":{"name":"slow.tool","arguments":{},"timeoutSecs":1}}
JSON

(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" ./bin/mcp-bash <"${WORKSPACE}/requests.ndjson" >"${WORKSPACE}/responses.ndjson"
)

assert_json_lines "${WORKSPACE}/responses.ndjson"

fail_resp="$(jq -c 'select(.id=="fail")' "${WORKSPACE}/responses.ndjson")"
if [ -z "${fail_resp}" ]; then
	test_fail "missing fail response"
fi
if jq -e 'select(.id=="fail") | .error._mcpToolError' "${WORKSPACE}/responses.ndjson" >/dev/null 2>&1; then
	:
fi
fail_code="$(echo "${fail_resp}" | jq -r '.error.code')"
fail_stderr="$(echo "${fail_resp}" | jq -r '.error.data._meta.stderr // empty')"
test_assert_eq "${fail_code}" "-32603"
if [ -z "${fail_stderr}" ] || [[ "${fail_stderr}" != *"nope"* ]]; then
	test_fail "stderr not propagated from fail.tool"
fi

slow_resp="$(jq -c 'select(.id=="slow")' "${WORKSPACE}/responses.ndjson")"
if [ -z "${slow_resp}" ]; then
	test_fail "missing slow response"
fi
slow_code="$(echo "${slow_resp}" | jq -r '.error.code')"
test_assert_eq "${slow_code}" "-32603"

printf 'Tool error and timeout tests passed.\n'
