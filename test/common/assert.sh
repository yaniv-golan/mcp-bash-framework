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
