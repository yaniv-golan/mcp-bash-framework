#!/usr/bin/env bash
# Integration: protocol version negotiation for unsupported and invalid versions.
# MCP 2025-11-25 (Lifecycle > Version Negotiation): a server that does not
# support the requested version MUST respond with another version it supports
# (SHOULD be its latest). A non-string protocolVersion is invalid params.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Unsupported protocol versions negotiate to the latest; non-string versions return -32602."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

LATEST="2025-11-25"

# run_init <name> <params-json> [extra env assignments...]
# Sends a single initialize request; responses land in ${TMP}/<name>.out and
# stderr in ${TMP}/<name>.err.
run_init() {
	local name="$1"
	local params="$2"
	shift 2
	printf '{"jsonrpc":"2.0","id":"init","method":"initialize","params":%s}\n' "${params}" >"${TMP}/${name}.in"
	env "$@" "${MCPBASH_HOME}/examples/run" 00-hello-tool <"${TMP}/${name}.in" >"${TMP}/${name}.out" 2>"${TMP}/${name}.err" || true
}

# assert_negotiated <name> <expected-version>
assert_negotiated() {
	local name="$1"
	local expected="$2"
	local err version
	err="$(jq -c 'select(.id=="init") | .error // empty' "${TMP}/${name}.out")"
	if [ -n "${err}" ]; then
		test_fail "${name}: expected an initialize result, got error ${err}"
	fi
	version="$(jq -r 'select(.id=="init") | .result.protocolVersion // empty' "${TMP}/${name}.out")"
	test_assert_eq "${version}" "${expected}"
}

# Unsupported dates, older and newer than anything supported, negotiate to the
# latest supported version and leave a note on stderr.
for requested in "2024-10-07" "2099-01-01" "1.0.0"; do
	run_init "unsupported-${requested}" "{\"protocolVersion\":\"${requested}\"}"
	assert_negotiated "unsupported-${requested}" "${LATEST}"
	if ! grep -q "unsupported protocol version ${requested}" "${TMP}/unsupported-${requested}.err"; then
		test_fail "unsupported-${requested}: expected a stderr note; got: $(cat "${TMP}/unsupported-${requested}.err")"
	fi
done

# Same negotiation in minimal mode (no JSON tooling).
run_init "minimal-future" '{"protocolVersion":"2099-01-01"}' MCPBASH_FORCE_MINIMAL=true
assert_negotiated "minimal-future" "${LATEST}"

# Supported versions are still honoured exactly, with no unsupported note.
for requested in "2025-11-25" "2025-06-18" "2025-03-26" "2024-11-05"; do
	run_init "supported-${requested}" "{\"protocolVersion\":\"${requested}\"}"
	assert_negotiated "supported-${requested}" "${requested}"
	if grep -q "unsupported protocol version" "${TMP}/supported-${requested}.err"; then
		test_fail "supported-${requested}: unexpected unsupported-version note"
	fi
done

# A missing (or null) protocolVersion keeps meaning "the default", which many
# existing clients and fixtures rely on.
run_init "missing" '{}'
assert_negotiated "missing" "${LATEST}"
run_init "null" '{"protocolVersion":null}'
assert_negotiated "null" "${LATEST}"

# A non-string protocolVersion is invalid params, with the spec's data shape.
for value in '42' 'true' '{"v":"2025-11-25"}' '["2025-11-25"]'; do
	run_init "invalid" "{\"protocolVersion\":${value}}"
	code="$(jq -r 'select(.id=="init") | .error.code // empty' "${TMP}/invalid.out")"
	test_assert_eq "${code}" "-32602"
	requested_json="$(jq -c 'select(.id=="init") | .error.data.requested' "${TMP}/invalid.out")"
	expected_json="$(printf '%s' "${value}" | jq -c '.')"
	test_assert_eq "${requested_json}" "${expected_json}"
	supported_json="$(jq -c 'select(.id=="init") | .error.data.supported' "${TMP}/invalid.out")"
	test_assert_eq "${supported_json}" '["2025-11-25","2025-06-18","2025-03-26","2024-11-05"]'
	message="$(jq -r 'select(.id=="init") | .error.message // empty' "${TMP}/invalid.out")"
	if [[ "${message}" != *"Unsupported protocol version"* ]]; then
		test_fail "invalid ${value}: unexpected error message: ${message}"
	fi
done

# Minimal mode reports a non-string version the same way.
run_init "minimal-invalid" '{"protocolVersion":42}' MCPBASH_FORCE_MINIMAL=true
code="$(jq -r 'select(.id=="init") | .error.code // empty' "${TMP}/minimal-invalid.out")"
test_assert_eq "${code}" "-32602"
test_assert_eq "$(jq -c 'select(.id=="init") | .error.data.requested' "${TMP}/minimal-invalid.out")" '42'
test_assert_eq "$(jq -c 'select(.id=="init") | .error.data.supported' "${TMP}/minimal-invalid.out")" '["2025-11-25","2025-06-18","2025-03-26","2024-11-05"]'

printf 'Protocol unsupported-version negotiation test passed.\n'
