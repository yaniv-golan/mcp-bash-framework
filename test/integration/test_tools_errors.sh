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
mkdir -p "${WORKSPACE}/tmp"
STATE_DIR="${WORKSPACE}/tmp/mcpbash.state.test"
mkdir -p "${STATE_DIR}"
LOG_DIR="${WORKSPACE}/logs"
rm -rf "${LOG_DIR}" 2>/dev/null || true
mkdir -p "${LOG_DIR}"

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
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" MCPBASH_TMP_ROOT="${WORKSPACE}/tmp" MCPBASH_STATE_DIR="${STATE_DIR}" MCPBASH_TRACE_TOOLS=true MCPBASH_PRESERVE_STATE=true MCPBASH_CI_MODE=true MCPBASH_LOG_DIR="${LOG_DIR}" ./bin/mcp-bash <"${WORKSPACE}/requests.ndjson" >"${WORKSPACE}/responses.ndjson"
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
fail_exit_code="$(echo "${fail_resp}" | jq -r '.error.data.exitCode // empty')"
test_assert_eq "${fail_exit_code}" "7"
fail_stderr_tail="$(echo "${fail_resp}" | jq -r '.error.data.stderrTail // empty')"
if [ -z "${fail_stderr_tail}" ] || [[ "${fail_stderr_tail}" != *"nope"* ]]; then
	test_fail "stderrTail missing or incorrect for fail.tool"
fi

slow_resp="$(jq -c 'select(.id=="slow")' "${WORKSPACE}/responses.ndjson")"
if [ -z "${slow_resp}" ]; then
	test_fail "missing slow response"
fi
slow_code="$(echo "${slow_resp}" | jq -r '.error.code')"
test_assert_eq "${slow_code}" "-32603"
slow_exit_code="$(echo "${slow_resp}" | jq -r '.error.data.exitCode // empty')"
case "${slow_exit_code}" in
124 | 137 | 143) ;;
*) test_fail "unexpected timeout exit code: ${slow_exit_code}" ;;
esac
slow_stderr_tail="$(echo "${slow_resp}" | jq -r '.error.data.stderrTail // empty')"
if [ -n "${slow_stderr_tail}" ] && [ "${#slow_stderr_tail}" -gt 4096 ]; then
	test_fail "timeout stderrTail exceeds expected cap"
fi

trace_file="$(find "${LOG_DIR}" "${STATE_DIR}" -name 'trace.*.log' -type f -print -quit 2>/dev/null || true)"
if [ -z "${trace_file}" ] || [ ! -f "${trace_file}" ]; then
	test_fail "trace file missing"
fi

summary_file="$(find "${LOG_DIR}" "${WORKSPACE}/tmp" "${TMPDIR:-/tmp}" -maxdepth 4 -name 'failure-summary.jsonl' -type f -print -quit 2>/dev/null || true)"
if [ -z "${summary_file}" ] || [ ! -f "${summary_file}" ]; then
	test_fail "failure summary missing"
fi
fail_summary_tool="$(head -n1 "${summary_file}" | jq -r '.tool // empty')"
if [ "${fail_summary_tool}" != "fail.tool" ]; then
	test_fail "failure summary missing fail.tool entry"
fi
env_snapshot="$(find "${LOG_DIR}" "${WORKSPACE}/tmp" "${TMPDIR:-/tmp}" -maxdepth 4 -name 'env-snapshot.json' -type f -print -quit 2>/dev/null || true)"
if [ -z "${env_snapshot}" ] || [ ! -f "${env_snapshot}" ]; then
	test_fail "env snapshot missing"
fi
if ! jq -e '.bashVersion and .os and .cwd' "${env_snapshot}" >/dev/null 2>&1; then
	test_fail "env snapshot missing required fields"
fi

printf 'Tool error and timeout tests passed.\n'
