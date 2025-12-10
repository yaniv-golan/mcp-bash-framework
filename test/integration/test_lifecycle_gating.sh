#!/usr/bin/env bash
# Integration: lifecycle gating, shutdown handling, and exit semantics.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Lifecycle gating for init, shutdown, and exit."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq

run_requests() {
	local req_file="$1"
	local resp_file="$2"
	test_run_mcp "${WORKSPACE}" "${req_file}" "${resp_file}"
	assert_json_lines "${resp_file}"
}

assert_error_code() {
	local resp_file="$1"
	local id="$2"
	local expected_code="$3"
	local expected_message="$4"
	local code message
	code="$(jq -r --arg id "${id}" 'select(.id == $id) | .error.code // empty' "${resp_file}")"
	message="$(jq -r --arg id "${id}" 'select(.id == $id) | .error.message // empty' "${resp_file}")"
	test_assert_eq "${code}" "${expected_code}"
	if [ -n "${expected_message}" ]; then
		if [ "${message}" != "${expected_message}" ]; then
			test_fail "message mismatch for ${id}: got '${message}', want '${expected_message}'"
		fi
	fi
}

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/lifecycle"
test_stage_workspace "${WORKSPACE}"

# 1) Pre-init call should be rejected.
cat <<'JSON' >"${WORKSPACE}/preinit.ndjson"
{"jsonrpc":"2.0","id":"pre","method":"tools/list"}
JSON
run_requests "${WORKSPACE}/preinit.ndjson" "${WORKSPACE}/preinit.resp"
resp_file="${WORKSPACE}/preinit.resp"
assert_error_code "${resp_file}" "pre" "-32002" "Server not initialized"

# 2) Double initialize should error on second call.
cat <<'JSON' >"${WORKSPACE}/double-init.ndjson"
{"jsonrpc":"2.0","id":"init1","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"init2","method":"initialize","params":{}}
{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}
{"jsonrpc":"2.0","id":"exit","method":"exit"}
JSON
run_requests "${WORKSPACE}/double-init.ndjson" "${WORKSPACE}/double-init.resp"
resp_file="${WORKSPACE}/double-init.resp"
if ! jq -e 'select(.id=="init1") | .result.protocolVersion == "2025-11-25"' "${resp_file}" >/dev/null; then
	test_fail "initial initialize failed"
fi
assert_error_code "${resp_file}" "init2" "-32600" "Server already initialized"

# 3) Exit before shutdown should be rejected.
cat <<'JSON' >"${WORKSPACE}/exit-before-shutdown.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"exit-early","method":"exit"}
{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}
{"jsonrpc":"2.0","id":"exit","method":"exit"}
JSON
run_requests "${WORKSPACE}/exit-before-shutdown.ndjson" "${WORKSPACE}/exit-before-shutdown.resp"
resp_file="${WORKSPACE}/exit-before-shutdown.resp"
assert_error_code "${resp_file}" "exit-early" "-32005" "Shutdown not requested"

# 4) During-shutdown requests should be rejected.
cat <<'JSON' >"${WORKSPACE}/shutdown-gating.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}
{"jsonrpc":"2.0","id":"during","method":"tools/list"}
{"jsonrpc":"2.0","id":"exit","method":"exit"}
JSON
run_requests "${WORKSPACE}/shutdown-gating.ndjson" "${WORKSPACE}/shutdown-gating.resp"
resp_file="${WORKSPACE}/shutdown-gating.resp"
assert_error_code "${resp_file}" "during" "-32003" "Server shutting down"

# 5) Shutdown without explicit exit should still terminate cleanly.
cat <<'JSON' >"${WORKSPACE}/shutdown-no-exit.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}
JSON
run_requests "${WORKSPACE}/shutdown-no-exit.ndjson" "${WORKSPACE}/shutdown-no-exit.resp"
resp_file="${WORKSPACE}/shutdown-no-exit.resp"
if ! jq -e 'select(.id=="shutdown") | .result == {}' "${resp_file}" >/dev/null; then
	test_fail "shutdown without exit did not respond successfully"
fi

printf 'Lifecycle gating tests passed.\n'
