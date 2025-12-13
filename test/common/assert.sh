#!/usr/bin/env bash
# Lightweight assertion helpers for shell tests.

set -euo pipefail

test_fail() {
	local message="${1:-assertion failed}"
	# Best-effort: capture a failure bundle into MCPBASH_LOG_DIR when configured.
	# This makes CI failures (especially on Windows runners) diagnosable from artifacts.
	if command -v test_capture_failure_bundle >/dev/null 2>&1; then
		local label="${TEST_FAILURE_BUNDLE_LABEL:-test}"
		local workspace="${TEST_FAILURE_BUNDLE_WORKSPACE:-}"
		local state_dir="${TEST_FAILURE_BUNDLE_STATE_DIR:-}"
		# Space/newline separated list of extra files to copy (best-effort).
		# shellcheck disable=SC2086
		test_capture_failure_bundle "${label}" "${workspace}" "${state_dir}" ${TEST_FAILURE_BUNDLE_EXTRA_FILES:-} || true
	fi

	# Auto-dump extra files to stderr so they appear in CI logs, not just artifacts.
	# This saves a round-trip when diagnosing failures.
	if [ -n "${TEST_FAILURE_BUNDLE_EXTRA_FILES:-}" ]; then
		local f
		# shellcheck disable=SC2086
		for f in ${TEST_FAILURE_BUNDLE_EXTRA_FILES}; do
			if [ -f "${f}" ] && [ -s "${f}" ]; then
				printf '\n=== %s ===\n' "${f}" >&2
				cat "${f}" >&2 || true
			fi
		done
		printf '\n=== End extra files ===\n' >&2
	fi

	printf 'ASSERTION FAILED: %s\n' "${message}" >&2
	exit 1
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="${3:-expected ${expected}, got ${actual}}"
	if [ "${expected}" != "${actual}" ]; then
		test_fail "${message}"
	fi
}

assert_contains() {
	local needle="$1"
	local haystack="$2"
	local message="${3:-expected to find \"${needle}\" in ${haystack}}"
	if ! grep -q -- "${needle}" <<<"${haystack}"; then
		test_fail "${message}"
	fi
}

assert_file_exists() {
	local path="$1"
	if [ ! -f "${path}" ]; then
		test_fail "expected file ${path}"
	fi
}

assert_json_lines() {
	local path="$1"
	while IFS= read -r line || [ -n "${line}" ]; do
		local trimmed="${line#"${line%%[![:space:]]*}"}"
		if [ -z "${trimmed}" ]; then
			continue
		fi
		if ! echo "${line}" | jq . >/dev/null 2>&1; then
			test_fail "line is not valid JSON: ${line}"
		fi
	done <"${path}"
}

# Backwards compatibility wrappers for older test helpers.
test_assert_eq() {
	local actual="$1"
	local expected="$2"
	local message="${3:-expected ${expected}, got ${actual}}"
	assert_eq "${expected}" "${actual}" "${message}"
}

# -----------------------------------------------------------------------------
# NDJSON assertion helpers
# These use jq -s (slurp) to correctly handle newline-delimited JSON files.
# Without -s, jq processes each line independently, which breaks array
# comprehensions and -e semantics.
# -----------------------------------------------------------------------------

# Assert that at least one line in an NDJSON file matches the given jq filter.
# Usage: assert_ndjson_has <file> <jq_filter> [message]
# Example: assert_ndjson_has responses.ndjson '.method == "notifications/progress"'
assert_ndjson_has() {
	local file="$1"
	local filter="$2"
	local message="${3:-expected NDJSON to have entry matching: ${filter}}"

	if [ ! -f "${file}" ]; then
		test_fail "NDJSON file not found: ${file}"
	fi

	local count
	count="$(jq -s "[.[] | select(${filter})] | length" "${file}" 2>/dev/null)" || count="0"

	if [ "${count}" = "0" ]; then
		printf '\n=== NDJSON content (%s) ===\n' "${file}" >&2
		jq -c '.' "${file}" >&2 || cat "${file}" >&2
		printf '=== End NDJSON ===\n' >&2
		test_fail "${message}"
	fi
}

# Assert that exactly N lines in an NDJSON file match the given jq filter.
# Usage: assert_ndjson_count <file> <jq_filter> <expected_count> [message]
assert_ndjson_count() {
	local file="$1"
	local filter="$2"
	local expected="$3"
	local message="${4:-expected ${expected} NDJSON entries matching: ${filter}}"

	if [ ! -f "${file}" ]; then
		test_fail "NDJSON file not found: ${file}"
	fi

	local actual
	actual="$(jq -s "[.[] | select(${filter})] | length" "${file}" 2>/dev/null)" || actual="0"

	if [ "${actual}" != "${expected}" ]; then
		printf '\n=== NDJSON content (%s) ===\n' "${file}" >&2
		jq -c '.' "${file}" >&2 || cat "${file}" >&2
		printf '=== Matching entries ===\n' >&2
		jq -c "select(${filter})" "${file}" >&2 || true
		printf '=== End NDJSON (expected %s, got %s) ===\n' "${expected}" "${actual}" >&2
		test_fail "${message} (expected ${expected}, got ${actual})"
	fi
}

# Assert that at least N lines in an NDJSON file match the given jq filter.
# Usage: assert_ndjson_min <file> <jq_filter> <min_count> [message]
assert_ndjson_min() {
	local file="$1"
	local filter="$2"
	local min="$3"
	local message="${4:-expected at least ${min} NDJSON entries matching: ${filter}}"

	if [ ! -f "${file}" ]; then
		test_fail "NDJSON file not found: ${file}"
	fi

	local actual
	actual="$(jq -s "[.[] | select(${filter})] | length" "${file}" 2>/dev/null)" || actual="0"

	if [ "${actual}" -lt "${min}" ]; then
		printf '\n=== NDJSON content (%s) ===\n' "${file}" >&2
		jq -c '.' "${file}" >&2 || cat "${file}" >&2
		printf '=== Matching entries ===\n' >&2
		jq -c "select(${filter})" "${file}" >&2 || true
		printf '=== End NDJSON (expected >= %s, got %s) ===\n' "${min}" "${actual}" >&2
		test_fail "${message} (expected >= ${min}, got ${actual})"
	fi
}

# Assert that an NDJSON file contains an entry matching a filter AND that entry
# passes additional validation. Useful for checking response shapes.
# Usage: assert_ndjson_shape <file> <select_filter> <shape_filter> [message]
# Example: assert_ndjson_shape resp.ndjson '.id == "foo"' '.result.tools | type == "array"'
assert_ndjson_shape() {
	local file="$1"
	local select_filter="$2"
	local shape_filter="$3"
	local message="${4:-NDJSON entry shape mismatch}"

	if [ ! -f "${file}" ]; then
		test_fail "NDJSON file not found: ${file}"
	fi

	# First check that any entry matches the selector
	local count
	count="$(jq -s "[.[] | select(${select_filter})] | length" "${file}" 2>/dev/null)" || count="0"
	if [ "${count}" = "0" ]; then
		printf '\n=== NDJSON content (%s) ===\n' "${file}" >&2
		jq -c '.' "${file}" >&2 || cat "${file}" >&2
		printf '=== End NDJSON ===\n' >&2
		test_fail "${message}: no entry matches selector (${select_filter})"
	fi

	# Then check that the matching entry passes the shape filter
	if ! jq -e "select(${select_filter}) | ${shape_filter}" "${file}" >/dev/null 2>&1; then
		printf '\n=== Matching entry ===\n' >&2
		jq -c "select(${select_filter})" "${file}" >&2 || true
		printf '=== Expected shape: %s ===\n' "${shape_filter}" >&2
		test_fail "${message}"
	fi
}
