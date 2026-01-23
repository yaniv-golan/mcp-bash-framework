#!/usr/bin/env bats
# Unit layer: validate debug file detection from lib/runtime.sh.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../../node_modules/bats-file/load'
load '../common/fixtures'

setup() {
	# Unset stale values BEFORE sourcing runtime.sh
	unset MCPBASH_SERVER_DIR
	unset MCPBASH_LOG_LEVEL
	unset _MCPBASH_DEBUG_VIA_FILE

	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"

	export MCPBASH_TMP_ROOT="${BATS_TEST_TMPDIR}"
	export MCPBASH_PROJECT_ROOT="${BATS_TEST_TMPDIR}"
	mkdir -p "${BATS_TEST_TMPDIR}/server.d"
}

@test "debug file: absent - MCPBASH_LOG_LEVEL unchanged" {
	mcp_runtime_init_paths
	assert_equal "${MCPBASH_LOG_LEVEL:-unset}" "unset"
}

@test "debug file: present - sets MCPBASH_LOG_LEVEL=debug" {
	touch "${BATS_TEST_TMPDIR}/server.d/.debug"
	mcp_runtime_init_paths
	assert_equal "${MCPBASH_LOG_LEVEL}" "debug"
}

@test "debug file: env var takes precedence" {
	export MCPBASH_LOG_LEVEL="warning"
	touch "${BATS_TEST_TMPDIR}/server.d/.debug"
	mcp_runtime_init_paths
	assert_equal "${MCPBASH_LOG_LEVEL}" "warning"
}

@test "debug file: logs detection message when enabled via file" {
	touch "${BATS_TEST_TMPDIR}/server.d/.debug"
	run mcp_runtime_init_paths
	# The deferred log message should appear in stderr
	assert_output --partial "(debug enabled via server.d/.debug file)"
}

@test "debug file: empty file enables debug (confirms existence-only check)" {
	touch "${BATS_TEST_TMPDIR}/server.d/.debug"
	[ ! -s "${BATS_TEST_TMPDIR}/server.d/.debug" ]  # Confirm file is empty
	mcp_runtime_init_paths
	assert_equal "${MCPBASH_LOG_LEVEL}" "debug"
}

@test "debug file: MCP logging level synced after detection" {
	# Source logging.sh to get MCP_LOG_LEVEL_CURRENT
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/logging.sh"

	# Before: MCP logging level should be info (default)
	assert_equal "${MCP_LOG_LEVEL_CURRENT}" "info"

	# Create .debug file and init paths
	touch "${BATS_TEST_TMPDIR}/server.d/.debug"
	mcp_runtime_init_paths

	# Simulate what mcp_core_bootstrap_state does after init_paths
	if [ -n "${MCPBASH_LOG_LEVEL:-}" ]; then
		mcp_logging_set_level "${MCPBASH_LOG_LEVEL}"
	fi

	# After: MCP logging level should be synced to debug
	assert_equal "${MCP_LOG_LEVEL_CURRENT}" "debug"
	# And debug logging should be enabled
	mcp_logging_is_enabled "debug"
}
