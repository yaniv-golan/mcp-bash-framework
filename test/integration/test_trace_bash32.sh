#!/usr/bin/env bash
# Integration: trace logging fallback on bash 3.2.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Trace logging fallback on bash 3.2."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
	printf 'Skipping bash 3.2 trace fallback test (bash %s)\n' "${BASH_VERSION}"
	exit 0
fi

test_require_command jq

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/trace-bash32"
test_stage_workspace "${WORKSPACE}"

mkdir -p "${WORKSPACE}/tools/trace"
cat <<'META' >"${WORKSPACE}/tools/trace/tool.meta.json"
{"name":"trace.tool","description":"trace log repro","arguments":{"type":"object","properties":{}}}
META
cat <<'SH' >"${WORKSPACE}/tools/trace/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
printf 'ok\n'
SH
chmod +x "${WORKSPACE}/tools/trace/tool.sh"

LOG_DIR="${WORKSPACE}/logs"
mkdir -p "${LOG_DIR}"

(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" MCPBASH_TRACE_TOOLS=true MCPBASH_LOG_DIR="${LOG_DIR}" \
		./bin/mcp-bash run-tool trace.tool --args '{}' >/dev/null
) || true

trace_log="$(find "${LOG_DIR}" -type f -name 'trace.*.log' -print 2>/dev/null | head -n 1 || true)"
if [[ -z "${trace_log}" ]]; then
	test_fail "expected trace log file under ${LOG_DIR}"
fi
if [[ ! -s "${trace_log}" ]]; then
	test_fail "expected non-empty trace log under ${LOG_DIR}"
fi

printf 'Trace fallback test passed.\n'
