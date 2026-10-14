#!/usr/bin/env bash
# Integration: core protocol errors, gating, and batch rejection.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Core error normalization, gating, and batch rejection."

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
WORKSPACE="${TEST_TMPDIR}/core-errors"
test_stage_workspace "${WORKSPACE}"

REQUESTS="${WORKSPACE}/requests.ndjson"
cat <<'JSON' >"${REQUESTS}"
not-json
{"jsonrpc":"2.0","id":"missing-method","params":{}}
{"jsonrpc":"2.0","id":"preinit","method":"tools/list"}
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"unknown","method":"foo/bar"}
[{"jsonrpc":"2.0","id":"batch","method":"ping"}]
JSON

RESPONSES="${WORKSPACE}/responses.ndjson"
test_run_mcp "${WORKSPACE}" "${REQUESTS}" "${RESPONSES}"

assert_json_lines "${RESPONSES}"

codes="$(
	jq -r -s '
		def first_code(filter_expr):
			(first(.[] | select(filter_expr) | .error.code) // "");
		{
			parse:   first_code(.error.message == "Parse error"),
			missing: first_code(.error.data == "Missing method"),
			preinit: first_code(.id == "preinit"),
			unknown: first_code(.id == "unknown"),
			batch:   first_code((.error.data // "") | (type == "string" and contains("Batch arrays")))
		} | to_entries[] | "\(.key)=\(.value)"
	' "${RESPONSES}"
)"

expect_code() {
	local key="$1" want="$2"
	if ! printf '%s\n' "${codes}" | grep -Fq "${key}=${want}"; then
		printf 'Expected %s code %s, got:\n%s\n' "${key}" "${want}" "${codes}" >&2
		exit 1
	fi
}

expect_code "parse" "-32700"
expect_code "missing" "-32600"
expect_code "preinit" "-32000"
expect_code "unknown" "-32601"
expect_code "batch" "-32600"

# MCPBASH_COMPAT_BATCHES is gone in 2.0: setting it doesn't enable batch
# arrays on protocols that don't have them (2025-03-26 keeps them).
RESPONSES_COMPAT="${WORKSPACE}/responses-compat.ndjson"
MCPBASH_COMPAT_BATCHES=true test_run_mcp "${WORKSPACE}" "${REQUESTS}" "${RESPONSES_COMPAT}"
assert_json_lines "${RESPONSES_COMPAT}"
if jq -e 'select(.id == "batch") | .result' "${RESPONSES_COMPAT}" >/dev/null 2>&1; then
	test_fail "MCPBASH_COMPAT_BATCHES=true still enables batches"
fi
jq -e 'select(.error.code == -32600 and ((.error.data // "") | type == "string" and contains("Batch arrays")))' "${RESPONSES_COMPAT}" >/dev/null \
	|| test_fail "batch not rejected with MCPBASH_COMPAT_BATCHES=true"

printf 'Core error handling tests passed.\n'
