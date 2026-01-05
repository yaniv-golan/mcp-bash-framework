#!/usr/bin/env bats
# Unit layer: SDK mcp_with_retry helper function.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# Source runtime for logging
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"

	mcp_runtime_detect_json_tool

	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"
}

@test "sdk_with_retry: succeeds on first attempt" {
	counter_file="${BATS_TEST_TMPDIR}/counter1"
	echo "0" >"${counter_file}"
	result=$(mcp_with_retry 3 0.1 -- bash -c "echo success")
	assert_equal "success" "${result}"
}

@test "sdk_with_retry: does not retry exit code 1" {
	counter_file="${BATS_TEST_TMPDIR}/counter2"
	echo "0" >"${counter_file}"
	run mcp_with_retry 3 0.1 -- bash -c 'exit 1'
	assert_failure
}

@test "sdk_with_retry: does not retry exit code 2" {
	run mcp_with_retry 3 0.1 -- bash -c 'exit 2'
	assert_failure
}

@test "sdk_with_retry: retries exit code 3 and eventually succeeds" {
	counter_file="${BATS_TEST_TMPDIR}/counter3"
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
	assert_equal "3" "${count}"
	assert_equal "success after retries" "${result}"
}

@test "sdk_with_retry: fails after max attempts" {
	counter_file="${BATS_TEST_TMPDIR}/counter4"
	echo "0" >"${counter_file}"
	run mcp_with_retry 3 0.05 -- bash -c "
		count=\$(cat '${counter_file}')
		count=\$((count + 1))
		echo \"\${count}\" > '${counter_file}'
		exit 3
	"
	assert_failure
	count=$(cat "${counter_file}")
	assert_equal "3" "${count}"
}

@test "sdk_with_retry: validates max_attempts" {
	run mcp_with_retry "abc" 1.0 -- echo test
	assert_failure
}

@test "sdk_with_retry: validates base_delay" {
	run mcp_with_retry 3 "abc" -- echo test
	assert_failure
}
