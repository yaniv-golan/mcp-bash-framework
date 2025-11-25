#!/usr/bin/env bash
# Minimal mode coverage: ensure the fallback JSON parser and reduced capability surface behave.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/workspace"
test_stage_workspace "${WORKSPACE}"

cat <<'JSON' >"${WORKSPACE}/requests.ndjson"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-03-26"}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"lvl-invalid","method":"logging/setLevel","params":{"level":"VERBOSE\\u0041","details":{"nested":[1,{"x":"y"}]}}}
{"jsonrpc":"2.0","id":"lvl-valid","method":"logging/setLevel","params":{"level":"DEBUG","meta":{"nested":[{"key":"value"},"x\\\"y"],"depth":{"inner":{"flag":true}}}}}
JSON

(
	cd "${WORKSPACE}" || exit 1
	MCPBASH_PROJECT_ROOT="${WORKSPACE}" \
		MCPBASH_FORCE_MINIMAL=true \
		./bin/mcp-bash <"${WORKSPACE}/requests.ndjson" >"${WORKSPACE}/responses.ndjson"
)

assert_file_exists "${WORKSPACE}/responses.ndjson"
assert_json_lines "${WORKSPACE}/responses.ndjson"

init_protocol="$(
	jq -r 'select(.id=="init") | .result.protocolVersion // empty' "${WORKSPACE}/responses.ndjson"
)"
assert_eq "2025-03-26" "${init_protocol}" "minimal mode should honor requested protocol negotiation"

init_caps="$(
	jq -c 'select(.id=="init") | .result.capabilities // empty' "${WORKSPACE}/responses.ndjson"
)"
assert_eq '{"logging":{}}' "${init_caps}" "minimal mode capabilities should be logging-only"

invalid_code="$(
	jq -r 'select(.id=="lvl-invalid") | .error.code // empty' "${WORKSPACE}/responses.ndjson"
)"
assert_eq "-32602" "${invalid_code}" "invalid log level should be rejected in minimal mode"

invalid_message="$(
	jq -r 'select(.id=="lvl-invalid") | .error.message // empty' "${WORKSPACE}/responses.ndjson"
)"
assert_eq "Invalid log level" "${invalid_message}" "invalid log level response message mismatch"

valid_response="$(
	jq -c 'select(.id=="lvl-valid") | .result // empty' "${WORKSPACE}/responses.ndjson"
)"
assert_eq '{}' "${valid_response}" "valid logging/setLevel should succeed in minimal mode"
