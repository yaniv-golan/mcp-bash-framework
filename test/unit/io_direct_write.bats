#!/usr/bin/env bats
# Unit: direct writes to a file descriptor (MCPBASH_DIRECT_FD) and the
# notification queue wrapper.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/lock.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/lock.sh"
	# shellcheck source=lib/io.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/io.sh"

	MCPBASH_TMP_ROOT="${BATS_TEST_TMPDIR}"
	export MCPBASH_PROJECT_ROOT="${BATS_TEST_TMPDIR}"
	mcp_runtime_init_paths
	MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/locks"
	mcp_lock_init
	MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	mkdir -p "${MCPBASH_STATE_DIR}"
	MCP_NOTIFICATION_QUEUE_FILE=""
	unset MCPBASH_DIRECT_FD
}

@test "io: a direct fd write releases the stdout lock" {
	local out="${BATS_TEST_TMPDIR}/direct.out"
	exec 7>"${out}"
	mcp_io_send_line_to_fd '{"jsonrpc":"2.0","method":"x"}' 7
	exec 7>&-
	assert_equal "$(cat "${out}")" '{"jsonrpc":"2.0","method":"x"}'
	[ ! -d "${MCPBASH_LOCK_ROOT}/${MCPBASH_STDOUT_LOCK_NAME}.lock" ] || fail "stdout lock still held after a direct write"
}

@test "io: queue_run keeps notifications out of a capture and flushes them after" {
	logs_inside() {
		mcp_notification_queue_append '{"n":1}'
		printf 'data'
	}
	build() {
		local captured
		captured="$(logs_inside)"
		printf 'captured=%s\n' "${captured}"
	}
	run mcp_notification_queue_run build
	assert_success
	assert_output $'captured=data\n{"n":1}'
	[ -z "${MCP_NOTIFICATION_QUEUE_FILE}" ] || fail "queue left active"
}

@test "io: queue_run uses an active queue and does not flush it" {
	mcp_notification_queue_init
	local queue="${MCP_NOTIFICATION_QUEUE_FILE}"
	mcp_notification_queue_run mcp_notification_queue_append '{"n":2}'
	assert_equal "${MCP_NOTIFICATION_QUEUE_FILE}" "${queue}"
	assert_equal "$(cat "${queue}")" '{"n":2}'
}

@test "io: queue_run passes the command's exit status through" {
	run mcp_notification_queue_run false
	assert_failure 1
}

@test "io: concurrent queue_run frames each flush only their own notifications" {
	FLUSHED_DIR="${BATS_TEST_TMPDIR}/flushed"
	mkdir -p "${FLUSHED_DIR}"
	two_appends() {
		mcp_notification_queue_append "{\"from\":\"$1\",\"n\":1}"
		sleep 1
		mcp_notification_queue_append "{\"from\":\"$1\",\"n\":2}"
	}
	frame() {
		# Each frame flushes into its own file, named by the frame.
		eval "mcp_io_send_line() { printf '%s\\n' \"\$1\" >>\"${FLUSHED_DIR}/$1\"; }"
		mcp_notification_queue_run two_appends "$1"
	}
	frame a &
	sleep 0.3
	frame b &
	wait
	assert_equal "$(cat "${FLUSHED_DIR}/a")" $'{"from":"a","n":1}\n{"from":"a","n":2}'
	assert_equal "$(cat "${FLUSHED_DIR}/b")" $'{"from":"b","n":1}\n{"from":"b","n":2}'
}
