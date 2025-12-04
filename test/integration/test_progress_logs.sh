#!/usr/bin/env bash
# Integration: progress/log emissions and rate limiting.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Progress and log notifications with rate limits."

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
WORKSPACE="${TEST_TMPDIR}/progress"
test_stage_workspace "${WORKSPACE}"

mkdir -p "${WORKSPACE}/tools/progress"
cat <<'META' >"${WORKSPACE}/tools/progress/tool.meta.json"
{"name":"progress.demo","description":"Emits progress and logs","arguments":{"type":"object","properties":{}}}
META
cat <<'SH' >"${WORKSPACE}/tools/progress/tool.sh"
#!/usr/bin/env bash
set -euo pipefail
source "${MCP_SDK}/tool-sdk.sh"
mcp_progress 5 "first"
mcp_progress 10 "second"
mcp_log_info "progress.demo" "log-one"
mcp_log_info "progress.demo" "log-two"
printf 'done'
SH
chmod +x "${WORKSPACE}/tools/progress/tool.sh"

cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"progress.demo","arguments":{},"_meta":{"progressToken":"tok"}}}
JSON

(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" \
		MCPBASH_MAX_PROGRESS_PER_MIN=1 \
		MCPBASH_MAX_LOGS_PER_MIN=1 \
		./bin/mcp-bash <"${WORKSPACE}/requests.ndjson" >"${WORKSPACE}/responses.ndjson"
)

assert_json_lines "${WORKSPACE}/responses.ndjson"

progress_count="$(jq -r 'select(.method=="notifications/progress") | .params.message' "${WORKSPACE}/responses.ndjson" | wc -l | tr -d ' ')"
log_count="$(jq -r 'select(.method=="notifications/message") | .params.logger' "${WORKSPACE}/responses.ndjson" | wc -l | tr -d ' ')"

if [ "${progress_count}" -ne 1 ]; then
	test_fail "expected 1 progress notification after rate limit, got ${progress_count}"
fi
if [ "${log_count}" -ne 1 ]; then
	test_fail "expected 1 log notification after rate limit, got ${log_count}"
fi

result_text="$(jq -r 'select(.id=="call") | .result.content[] | select(.type=="text") | .text' "${WORKSPACE}/responses.ndjson" | tr -d '\r')"
if [[ "${result_text}" != *"done"* ]]; then
	test_fail "tool result missing"
fi

printf 'Progress/log rate limit tests passed.\n'
