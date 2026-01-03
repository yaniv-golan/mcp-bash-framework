#!/usr/bin/env bash
# Unit layer: SDK mcp_with_retry helper function.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

# Source runtime for logging
# shellcheck source=lib/runtime.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/runtime.sh"

mcp_runtime_detect_json_tool

# shellcheck source=sdk/tool-sdk.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/sdk/tool-sdk.sh"

test_create_tmpdir

printf ' -> mcp_with_retry succeeds on first attempt\n'
counter_file="${TEST_TMPDIR}/counter1"
echo "0" >"${counter_file}"
result=$(mcp_with_retry 3 0.1 -- bash -c "echo success")
assert_eq "success" "${result}" "should output success on first attempt"

printf ' -> mcp_with_retry does not retry exit code 1\n'
counter_file="${TEST_TMPDIR}/counter2"
echo "0" >"${counter_file}"
if mcp_with_retry 3 0.1 -- bash -c 'exit 1' 2>/dev/null; then
	test_fail "should not succeed on exit code 1"
fi

printf ' -> mcp_with_retry does not retry exit code 2\n'
if mcp_with_retry 3 0.1 -- bash -c 'exit 2' 2>/dev/null; then
	test_fail "should not succeed on exit code 2"
fi

printf ' -> mcp_with_retry retries exit code 3 and eventually succeeds\n'
counter_file="${TEST_TMPDIR}/counter3"
echo "0" >"${counter_file}"
# This script exits 3 on first two attempts, then exits 0
result=$(mcp_with_retry 5 0.05 -- bash -c "
	count=\$(cat '${counter_file}')
	count=\$((count + 1))
	echo \"\${count}\" > '${counter_file}'
	if [ \${count} -lt 3 ]; then
		exit 3
	fi
	echo 'success after retries'
	exit 0
")
count=$(cat "${counter_file}")
assert_eq "3" "${count}" "should have run 3 times"
assert_eq "success after retries" "${result}" "should output success message"

printf ' -> mcp_with_retry fails after max attempts\n'
counter_file="${TEST_TMPDIR}/counter4"
echo "0" >"${counter_file}"
if mcp_with_retry 3 0.05 -- bash -c "
	count=\$(cat '${counter_file}')
	count=\$((count + 1))
	echo \"\${count}\" > '${counter_file}'
	exit 3
" 2>/dev/null; then
	test_fail "should fail after max attempts"
fi
count=$(cat "${counter_file}")
assert_eq "3" "${count}" "should have attempted exactly 3 times"

printf ' -> mcp_with_retry validates max_attempts\n'
if mcp_with_retry "abc" 1.0 -- echo test 2>/dev/null; then
	test_fail "should reject non-numeric max_attempts"
fi

printf ' -> mcp_with_retry validates base_delay\n'
if mcp_with_retry 3 "abc" -- echo test 2>/dev/null; then
	test_fail "should reject non-numeric base_delay"
fi

printf 'SDK mcp_with_retry tests passed.\n'
