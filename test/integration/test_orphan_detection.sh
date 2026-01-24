#!/usr/bin/env bash
# Integration: orphan detection triggers server exit when parent dies.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Orphan detection triggers exit when parent process dies."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq

# Skip on Windows where orphan detection is disabled by default
case "$(uname -s 2>/dev/null)" in
CYGWIN* | MINGW* | MSYS*)
	printf 'SKIP: Orphan detection disabled on Windows\n'
	exit 0
	;;
esac

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/orphan"
test_stage_workspace "${WORKSPACE}"

# Test 1: Orphan detection triggers when parent dies
test_orphan_detection() {
	local test_dir pid_file fifo_path
	local writer_pid=""

	test_dir=$(mktemp -d)
	pid_file="${test_dir}/pid"
	fifo_path="${test_dir}/fifo"
	mkfifo "${fifo_path}"
	# shellcheck disable=SC2064
	trap "rm -rf '${test_dir}'; kill '${writer_pid}' 2>/dev/null || true" RETURN

	# Open a writer to the FIFO first
	sleep 86400 >"${fifo_path}" &
	writer_pid=$!

	# Start server as child of a short-lived parent subshell
	(
		MCPBASH_ORPHAN_CHECK_INTERVAL=2 \
			MCPBASH_IDLE_TIMEOUT=0 \
			MCPBASH_PROJECT_ROOT="${WORKSPACE}" \
			"${WORKSPACE}/bin/mcp-bash" <"${fifo_path}" &
		printf '%s' "$!" >"${pid_file}"
		sleep 1
		# Parent subshell exits without killing child
	)

	local server_pid
	server_pid=$(cat "${pid_file}")

	if [ -z "${server_pid}" ]; then
		test_fail "Could not capture server PID"
	fi

	# Server should detect orphan status and exit within check interval + margin
	local wait_time=5
	local elapsed=0
	while [ "${elapsed}" -lt "${wait_time}" ]; do
		if ! kill -0 "${server_pid}" 2>/dev/null; then
			printf 'PASS: Orphaned server exited after ~%ds\n' "${elapsed}"
			return 0
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done

	kill "${server_pid}" 2>/dev/null || true
	test_fail "Orphaned server still running after ${wait_time}s"
}

# Test 2: Orphan detection disabled doesn't cause premature exit
test_orphan_detection_disabled() {
	local test_dir pid_file fifo_path
	local writer_pid=""

	test_dir=$(mktemp -d)
	pid_file="${test_dir}/pid"
	fifo_path="${test_dir}/fifo"
	mkfifo "${fifo_path}"
	# shellcheck disable=SC2064
	trap "rm -rf '${test_dir}'; kill '${writer_pid}' 2>/dev/null || true" RETURN

	sleep 86400 >"${fifo_path}" &
	writer_pid=$!

	# Start server with orphan detection disabled
	(
		MCPBASH_ORPHAN_CHECK_ENABLED=false \
			MCPBASH_IDLE_TIMEOUT=10 \
			MCPBASH_PROJECT_ROOT="${WORKSPACE}" \
			"${WORKSPACE}/bin/mcp-bash" <"${fifo_path}" &
		printf '%s' "$!" >"${pid_file}"
		sleep 1
	)

	local server_pid
	server_pid=$(cat "${pid_file}")

	# Server should NOT exit immediately
	sleep 3
	if kill -0 "${server_pid}" 2>/dev/null; then
		printf 'PASS: Server still running with orphan detection disabled\n'
		kill "${server_pid}" 2>/dev/null || true
		return 0
	else
		test_fail "Server exited unexpectedly with orphan detection disabled"
	fi
}

# Run tests
test_orphan_detection
test_orphan_detection_disabled
