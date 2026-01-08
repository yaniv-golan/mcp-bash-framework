#!/usr/bin/env bats
# Unit layer: validate progress-aware timeout from lib/timeout.sh.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../../node_modules/bats-file/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/timeout.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/timeout.sh"

	export MCPBASH_TMP_ROOT="${BATS_TEST_TMPDIR}"
	export MCPBASH_PROJECT_ROOT="${BATS_TEST_TMPDIR}"
	export MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	mkdir -p "${MCPBASH_STATE_DIR}"
	mcp_runtime_init_paths
}

teardown() {
	# Clean up any leftover state files
	rm -rf "${BATS_TEST_TMPDIR}/state" 2>/dev/null || true
}

@test "mcp_timeout_file_mtime: works on current platform" {
	# Verify stat flavor detection works
	[ "${#MCPBASH_STAT_MTIME_ARGS[@]}" -gt 0 ]

	# Create test file and verify mtime retrieval
	local test_file="${BATS_TEST_TMPDIR}/mtime_test"
	echo "test" > "${test_file}"
	local mtime
	mtime=$(mcp_timeout_file_mtime "${test_file}")

	# mtime should be numeric and recent (within last 10 seconds)
	[[ "${mtime}" =~ ^[0-9]+$ ]]
	local now
	now=$(date +%s)
	[ "$((now - mtime))" -lt 10 ]
}

@test "mcp_timeout_file_mtime: returns error for nonexistent file" {
	run mcp_timeout_file_mtime "${BATS_TEST_TMPDIR}/nonexistent"
	[ "$status" -ne 0 ]
}

@test "mcp_timeout_now: returns epoch seconds" {
	local now
	now=$(mcp_timeout_now)
	[[ "${now}" =~ ^[0-9]+$ ]]

	# Should be recent (within last 2 seconds of system time)
	local sys_now
	sys_now=$(date +%s)
	[ "$((sys_now - now))" -lt 2 ]
}

@test "progress_extends_timeout: resets on file touch" {
	export MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true
	export MCPBASH_MAX_TIMEOUT_SECS=60

	local progress_file="${BATS_TEST_TMPDIR}/progress.ndjson"
	export MCP_PROGRESS_STREAM="${progress_file}"
	: > "${progress_file}"

	# Tool sleeps but emits progress every 2s, total runtime 10s
	# Should complete even though idle timeout is 5s
	run with_timeout 5 -- bash -c '
		for i in 1 2 3 4 5; do
			sleep 2
			echo "{\"progress\":$i}" >> "'"${progress_file}"'"
		done
	'

	assert_success
}

@test "progress_extends_timeout: kills when no progress" {
	export MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true
	export MCP_PROGRESS_STREAM="${BATS_TEST_TMPDIR}/progress.ndjson"
	: > "${MCP_PROGRESS_STREAM}"

	# Tool that never emits progress - should timeout after 3 seconds
	run with_timeout 3 -- sleep 30

	# Should timeout (exit code 124)
	assert_failure 124
}

@test "progress_extends_timeout: respects hard cap" {
	export MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true
	export MCPBASH_MAX_TIMEOUT_SECS=5

	local progress_file="${BATS_TEST_TMPDIR}/progress.ndjson"
	export MCP_PROGRESS_STREAM="${progress_file}"
	: > "${progress_file}"

	# Tool that emits progress continuously but runs longer than hard cap
	run with_timeout 2 -- bash -c '
		for i in $(seq 1 20); do
			echo "{\"progress\":$i}" >> "'"${progress_file}"'"
			sleep 1
		done
	'

	# Should hit hard cap at 5 seconds despite continuous progress
	assert_failure 124
}

@test "progress_extends_timeout: handles stale progress file" {
	export MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true

	local progress_file="${BATS_TEST_TMPDIR}/progress.ndjson"
	export MCP_PROGRESS_STREAM="${progress_file}"

	# Create stale progress file with old mtime (simulating leftover from crash)
	echo '{"stale":"data"}' > "${progress_file}"
	touch -t 202001010000 "${progress_file}"  # Set mtime to Jan 1, 2020

	# Tool that does real work - should NOT immediately timeout due to stale mtime
	run with_timeout 5 -- bash -c '
		sleep 2
		echo "{\"progress\":1}" >> "'"${progress_file}"'"
		sleep 2
	'

	# Should complete successfully (stale mtime ignored, uses current time)
	assert_success
}

@test "progress_extends_timeout: handles rapid progress emission" {
	export MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true
	export MCPBASH_MAX_TIMEOUT_SECS=60

	local progress_file="${BATS_TEST_TMPDIR}/progress.ndjson"
	export MCP_PROGRESS_STREAM="${progress_file}"
	: > "${progress_file}"

	# Tool that emits progress very rapidly (faster than 1-second mtime granularity)
	# Should still extend timeout despite mtime only changing once per second
	run with_timeout 3 -- bash -c '
		for i in $(seq 1 50); do
			echo "{\"progress\":$i}" >> "'"${progress_file}"'"
			sleep 0.1
		done
	'

	# Should complete (takes ~5s, but timeout extends due to progress)
	assert_success
}

@test "progress_extends_timeout: disabled by default" {
	# Make sure feature is disabled
	unset MCPBASH_PROGRESS_EXTENDS_TIMEOUT

	local progress_file="${BATS_TEST_TMPDIR}/progress.ndjson"
	export MCP_PROGRESS_STREAM="${progress_file}"
	: > "${progress_file}"

	# Tool emits progress but feature is disabled - should still timeout
	run with_timeout 3 -- bash -c '
		for i in 1 2 3 4 5 6 7 8 9 10; do
			echo "{\"progress\":$i}" >> "'"${progress_file}"'"
			sleep 1
		done
	'

	# Should timeout since progress extension is disabled
	assert_failure 124
}

@test "timeout_reason: set to idle when progress times out" {
	export MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true
	export MCP_PROGRESS_STREAM="${BATS_TEST_TMPDIR}/progress.ndjson"
	: > "${MCP_PROGRESS_STREAM}"

	# Run tool that doesn't emit progress
	with_timeout 2 -- sleep 30 || true

	# Check timeout reason was set
	assert_equal "idle" "${MCPBASH_TIMEOUT_REASON}"
}

@test "timeout_reason: set to max_exceeded when hard cap hit" {
	export MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true
	export MCPBASH_MAX_TIMEOUT_SECS=3

	local progress_file="${BATS_TEST_TMPDIR}/progress.ndjson"
	export MCP_PROGRESS_STREAM="${progress_file}"
	: > "${progress_file}"

	# Tool that emits progress continuously past hard cap
	with_timeout 2 -- bash -c '
		for i in $(seq 1 20); do
			echo "{\"progress\":$i}" >> "'"${progress_file}"'"
			sleep 1
		done
	' || true

	# Check timeout reason was set
	assert_equal "max_exceeded" "${MCPBASH_TIMEOUT_REASON}"
}

@test "timeout_reason: set to fixed when feature disabled" {
	unset MCPBASH_PROGRESS_EXTENDS_TIMEOUT

	# Run tool that times out with feature disabled
	with_timeout 2 -- sleep 30 || true

	# Check timeout reason was set
	assert_equal "fixed" "${MCPBASH_TIMEOUT_REASON}"
}
