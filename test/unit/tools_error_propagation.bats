#!/usr/bin/env bats
# Unit tests for tool error propagation to handlers.
# Verifies that early-exit errors (e.g., tool not found) properly set
# _MCP_TOOLS_RESULT so handlers can parse the specific error code.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/hash.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/hash.sh"
	# shellcheck source=lib/lock.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/lock.sh"
	# shellcheck source=lib/registry.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/registry.sh"
	# shellcheck source=lib/tools.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/tools.sh"

	MCPBASH_JSON_TOOL_BIN="$(command -v jq)"
	MCPBASH_JSON_TOOL="jq"
	if ! command -v mcp_logging_is_enabled >/dev/null 2>&1; then
		mcp_logging_is_enabled() {
			return 1
		}
	fi
	if ! command -v mcp_logging_warning >/dev/null 2>&1; then
		mcp_logging_warning() {
			return 0
		}
	fi
	if ! command -v mcp_logging_debug >/dev/null 2>&1; then
		mcp_logging_debug() {
			return 0
		}
	fi

	MCPBASH_TMP_ROOT="${BATS_TEST_TMPDIR}"
	MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/locks"
	MCPBASH_REGISTRY_DIR="${BATS_TEST_TMPDIR}/registry"
	MCPBASH_TOOLS_DIR="${BATS_TEST_TMPDIR}/tools"
	MCPBASH_SERVER_DIR="${BATS_TEST_TMPDIR}/server.d"
	mkdir -p "${MCPBASH_STATE_DIR}" "${MCPBASH_LOCK_ROOT}" "${MCPBASH_REGISTRY_DIR}" "${MCPBASH_TOOLS_DIR}" "${MCPBASH_SERVER_DIR}"
	mcp_lock_init
}

@test "tools_error_propagation: tool not found sets _MCP_TOOLS_RESULT with -32602" {
	# Create an empty registry so no tools exist
	MCP_TOOLS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/tools.json"
	printf '{"hash":"empty","total":0,"items":[]}' >"${MCP_TOOLS_REGISTRY_PATH}"
	MCP_TOOLS_REGISTRY_JSON='{"hash":"empty","total":0,"items":[]}'
	MCP_TOOLS_REGISTRY_HASH="empty"
	MCP_TOOLS_TOTAL=0
	MCP_TOOLS_LAST_SCAN="$(date +%s)"
	MCP_TOOLS_TTL=5

	# Call non-existent tool - should fail and set _MCP_TOOLS_RESULT
	# Don't use 'run' - we need to access variables set by the function
	# Args: name, args_json, timeout_override, request_meta
	local call_status=0
	mcp_tools_call "nonexistent" "{}" "" "{}" || call_status=$?
	[ "${call_status}" -ne 0 ] || {
		echo "Expected mcp_tools_call to fail for non-existent tool" >&2
		false
	}

	# Verify _MCP_TOOLS_ERROR_CODE is set
	assert_equal "-32602" "${_MCP_TOOLS_ERROR_CODE}"

	# CRITICAL: Verify _MCP_TOOLS_RESULT is set with error JSON
	# This is the bug - mcp_tools_error() does NOT set _MCP_TOOLS_RESULT,
	# so handlers fall back to generic -32603 "Tool execution failed"
	[ -n "${_MCP_TOOLS_RESULT}" ] || {
		echo "_MCP_TOOLS_RESULT is empty - error not propagated to handlers" >&2
		false
	}

	# Verify result contains proper error structure
	local result_code
	result_code="$(printf '%s' "${_MCP_TOOLS_RESULT}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.code')"
	assert_equal "-32602" "${result_code}"

	# Verify tool name is included in error message for debugging
	local result_message
	result_message="$(printf '%s' "${_MCP_TOOLS_RESULT}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.message')"
	[[ "${result_message}" == *"nonexistent"* ]] || [[ "${result_message}" == *"not found"* ]]
}

@test "tools_error_propagation: tool path unavailable sets _MCP_TOOLS_RESULT with -32601" {
	# Create registry with tool that has empty path
	MCP_TOOLS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/tools.json"
	printf '{"hash":"pathless","total":1,"items":[{"name":"pathless","path":"","inputSchema":{}}]}' >"${MCP_TOOLS_REGISTRY_PATH}"
	MCP_TOOLS_REGISTRY_JSON='{"hash":"pathless","total":1,"items":[{"name":"pathless","path":"","inputSchema":{}}]}'
	MCP_TOOLS_REGISTRY_HASH="pathless"
	MCP_TOOLS_TOTAL=1
	MCP_TOOLS_LAST_SCAN="$(date +%s)"
	MCP_TOOLS_TTL=5

	# Call tool with empty path - should fail and set _MCP_TOOLS_RESULT
	# Don't use 'run' - we need to access variables set by the function
	# Args: name, args_json, timeout_override, request_meta
	local call_status=0
	mcp_tools_call "pathless" "{}" "" "{}" || call_status=$?
	[ "${call_status}" -ne 0 ] || {
		echo "Expected mcp_tools_call to fail for tool with no path" >&2
		false
	}

	# Verify _MCP_TOOLS_ERROR_CODE is set
	assert_equal "-32601" "${_MCP_TOOLS_ERROR_CODE}"

	# CRITICAL: Verify _MCP_TOOLS_RESULT is set with error JSON
	[ -n "${_MCP_TOOLS_RESULT}" ] || {
		echo "_MCP_TOOLS_RESULT is empty - error not propagated to handlers" >&2
		false
	}

	# Verify result contains proper error structure
	local result_code
	result_code="$(printf '%s' "${_MCP_TOOLS_RESULT}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.code')"
	assert_equal "-32601" "${result_code}"
}
