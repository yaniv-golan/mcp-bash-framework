#!/usr/bin/env bash
# Integration: progress-aware timeout extension.
# Tests that tools emitting progress survive past nominal timeout,
# while tools without progress timeout as expected.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Progress-aware timeout extension for long-running tools."

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
WORKSPACE="${TEST_TMPDIR}/progress-timeout"
test_stage_workspace "${WORKSPACE}"

# Copy test fixtures from examples/99-test-fixtures
FIXTURES_SRC="${MCPBASH_HOME}/examples/99-test-fixtures"
if [ ! -d "${FIXTURES_SRC}" ]; then
	test_fail "test fixtures not found: ${FIXTURES_SRC}"
fi
cp -a "${FIXTURES_SRC}/tools/." "${WORKSPACE}/tools/"

RESPONSES="${WORKSPACE}/responses.ndjson"

# --- Test 1: Tool with progress survives past nominal timeout ---
# The slow-with-progress tool has timeoutSecs=5 but runs for 8s with progress.
# With MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true, it should complete successfully.

cat <<'JSON' >"${WORKSPACE}/requests-with-progress.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"progress-tool","method":"tools/call","params":{"name":"slow-with-progress","arguments":{"duration":8},"_meta":{"progressToken":"pt-1"}}}
JSON

(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" \
		MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true \
		MCPBASH_MAX_TIMEOUT_SECS=60 \
		./bin/mcp-bash <"${WORKSPACE}/requests-with-progress.ndjson" >"${RESPONSES}" 2>/dev/null
) || true

assert_json_lines "${RESPONSES}"

progress_resp="$(jq -c 'select(.id=="progress-tool")' "${RESPONSES}")"
if [ -z "${progress_resp}" ]; then
	test_fail "missing progress-tool response"
fi

# Check for successful result (no error)
if echo "${progress_resp}" | jq -e '.error' >/dev/null 2>&1; then
	error_msg="$(echo "${progress_resp}" | jq -r '.error.message // "unknown"')"
	test_fail "slow-with-progress should complete successfully but got error: ${error_msg}"
fi

# Verify result contains expected completion message
result_text="$(echo "${progress_resp}" | jq -r '.result.content[0].text // empty')"
if [[ "${result_text}" != *"Completed"* ]]; then
	test_fail "slow-with-progress result should contain 'Completed': ${result_text}"
fi

printf 'Test 1 passed: tool with progress survives past nominal timeout.\n'

# --- Test 2: Tool without progress times out as expected ---
# The slow-no-progress tool has timeoutSecs=5 but runs for 10s without progress.
# Even with MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true, it should timeout after 5s idle.

cat <<'JSON' >"${WORKSPACE}/requests-no-progress.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"no-progress-tool","method":"tools/call","params":{"name":"slow-no-progress","arguments":{"duration":10}}}
JSON

(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" \
		MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true \
		MCPBASH_MAX_TIMEOUT_SECS=60 \
		./bin/mcp-bash <"${WORKSPACE}/requests-no-progress.ndjson" >"${WORKSPACE}/responses-no-progress.ndjson" 2>/dev/null
) || true

assert_json_lines "${WORKSPACE}/responses-no-progress.ndjson"

no_progress_resp="$(jq -c 'select(.id=="no-progress-tool")' "${WORKSPACE}/responses-no-progress.ndjson")"
if [ -z "${no_progress_resp}" ]; then
	test_fail "missing no-progress-tool response"
fi

# Check for error (timeout expected)
if ! echo "${no_progress_resp}" | jq -e '.error' >/dev/null 2>&1; then
	test_fail "slow-no-progress should timeout but got success"
fi

# Verify error code is -32603 (internal error for timeout)
error_code="$(echo "${no_progress_resp}" | jq -r '.error.code')"
test_assert_eq "${error_code}" "-32603"

# Verify error message mentions timeout
error_msg="$(echo "${no_progress_resp}" | jq -r '.error.message // empty')"
if [[ "${error_msg}" != *"timed out"* ]]; then
	test_fail "error message should mention timeout: ${error_msg}"
fi

# Verify idle timeout reason is included (no progress reported)
if [[ "${error_msg}" != *"no progress"* ]]; then
	# Acceptable if message just says "timed out" - the idle detail is optional
	printf 'Note: timeout message does not include idle reason (acceptable)\n'
fi

printf 'Test 2 passed: tool without progress times out as expected.\n'

# --- Test 3: Hard cap is enforced despite continuous progress ---
# Use a very low hard cap to test that max_timeout is enforced.

cat <<'JSON' >"${WORKSPACE}/requests-hard-cap.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"hard-cap-tool","method":"tools/call","params":{"name":"slow-with-progress","arguments":{"duration":20},"_meta":{"progressToken":"pt-3"}}}
JSON

(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" \
		MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true \
		MCPBASH_MAX_TIMEOUT_SECS=8 \
		./bin/mcp-bash <"${WORKSPACE}/requests-hard-cap.ndjson" >"${WORKSPACE}/responses-hard-cap.ndjson" 2>/dev/null
) || true

assert_json_lines "${WORKSPACE}/responses-hard-cap.ndjson"

hard_cap_resp="$(jq -c 'select(.id=="hard-cap-tool")' "${WORKSPACE}/responses-hard-cap.ndjson")"
if [ -z "${hard_cap_resp}" ]; then
	test_fail "missing hard-cap-tool response"
fi

# Check for error (hard cap timeout expected)
if ! echo "${hard_cap_resp}" | jq -e '.error' >/dev/null 2>&1; then
	test_fail "slow-with-progress should hit hard cap but got success"
fi

# Verify error code is -32603
hard_cap_code="$(echo "${hard_cap_resp}" | jq -r '.error.code')"
test_assert_eq "${hard_cap_code}" "-32603"

printf 'Test 3 passed: hard cap is enforced despite continuous progress.\n'

printf 'Progress-aware timeout tests passed.\n'
