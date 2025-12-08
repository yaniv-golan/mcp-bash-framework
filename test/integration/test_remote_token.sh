#!/usr/bin/env bash
# Integration: remote token guard enforces per-request shared secret.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Remote token guard rejects missing/invalid tokens and accepts valid ones."

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
WORKSPACE="${TEST_TMPDIR}/remote-token"
test_stage_workspace "${WORKSPACE}"

REQUESTS="${WORKSPACE}/requests.ndjson"
cat <<'JSON' >"${REQUESTS}"
{"jsonrpc":"2.0","id":"missing","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}
{"jsonrpc":"2.0","id":"bad","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"_meta":{"mcpbash/remoteToken":"wrong"}}}
{"jsonrpc":"2.0","id":"ok","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"_meta":{"mcpbash/remoteToken":"secret-token"}}}
JSON

RESPONSES="${WORKSPACE}/responses.ndjson"

MCPBASH_REMOTE_TOKEN="secret-token" test_run_mcp "${WORKSPACE}" "${REQUESTS}" "${RESPONSES}"

assert_json_lines "${RESPONSES}"

codes="$(
	jq -r '
		[
			(.id // "unknown"),
			(if has("error") then (.error.code|tostring) else "ok" end)
		] | @tsv
	' "${RESPONSES}"
)"

expect_code() {
	local id="$1" want="$2"
	local line
	line="$(printf '%s\n' "${codes}" | awk -v id="${id}" '$1==id {print $0}')"
	if [ -z "${line}" ]; then
		test_fail "Missing response for id=${id}"
	fi
	local have
	have="$(printf '%s' "${line}" | awk '{print $2}')"
	if [ "${have}" != "${want}" ]; then
		test_fail "id=${id} expected ${want}, got ${have}"
	fi
}

expect_code "missing" "-32602"
expect_code "bad" "-32602"
expect_code "ok" "ok"

printf 'Remote token guard integration passed.\n'
