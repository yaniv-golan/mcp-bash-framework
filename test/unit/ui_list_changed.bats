#!/usr/bin/env bats
# Unit tests for UI registry change -> resources/list_changed signalling (gap #3).
# UI resources surface in resources/list, so a change to the ui:// set reuses the
# existing MCP_RESOURCES_CHANGED pipeline (single, protocol-gated notification).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup_file() {
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable"
	fi
	export MCPBASH_MODE MCPBASH_JSON_TOOL MCPBASH_JSON_TOOL_BIN
}

setup() {
	TEST_TMPDIR="$(mktemp -d)"
	MCPBASH_STATE_DIR="${TEST_TMPDIR}/state"
	MCPBASH_REGISTRY_DIR="${TEST_TMPDIR}/state"
	MCPBASH_UI_DIR="${TEST_TMPDIR}/ui"
	MCPBASH_TOOLS_DIR="${TEST_TMPDIR}/tools"
	mkdir -p "${MCPBASH_STATE_DIR}" "${MCPBASH_UI_DIR}" "${MCPBASH_TOOLS_DIR}"
	export TEST_TMPDIR MCPBASH_STATE_DIR MCPBASH_REGISTRY_DIR MCPBASH_UI_DIR MCPBASH_TOOLS_DIR

	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/ui.sh"

	MCP_UI_REGISTRY_JSON=""
	MCP_UI_REGISTRY_HASH=""
	MCP_UI_TOTAL=0
	# Declare the resources changed-flag so the wiring can set it.
	MCP_RESOURCES_CHANGED=false

	mcp_logging_is_enabled() { return 1; }
}

teardown() {
	[ -d "${TEST_TMPDIR}" ] && rm -rf "${TEST_TMPDIR}"
}

_add_ui() {
	mkdir -p "${MCPBASH_UI_DIR}/$1"
	printf '%s' '<html></html>' >"${MCPBASH_UI_DIR}/$1/index.html"
}

@test "list_changed: initial generation does not set MCP_RESOURCES_CHANGED" {
	_add_ui "a"
	MCP_RESOURCES_CHANGED=false
	mcp_ui_generate_registry
	assert_equal "false" "${MCP_RESOURCES_CHANGED}"
}

@test "list_changed: adding a ui resource sets MCP_RESOURCES_CHANGED" {
	_add_ui "a"
	mcp_ui_generate_registry # initial
	MCP_RESOURCES_CHANGED=false

	_add_ui "b"
	mcp_ui_generate_registry # hash changes
	assert_equal "true" "${MCP_RESOURCES_CHANGED}"
}

@test "list_changed: regeneration with no change leaves flag false" {
	_add_ui "a"
	mcp_ui_generate_registry # initial
	MCP_RESOURCES_CHANGED=false

	mcp_ui_generate_registry # no fs change
	assert_equal "false" "${MCP_RESOURCES_CHANGED}"
}

@test "list_changed: refresh_registry (poll path) signals change when stale" {
	_add_ui "a"
	mcp_ui_generate_registry # initial populate
	MCP_RESOURCES_CHANGED=false

	# Simulate a change after the TTL window (this is what a poll observes).
	_add_ui "b"
	MCP_UI_LAST_SCAN=1 # force stale so refresh regenerates
	mcp_ui_refresh_registry
	assert_equal "true" "${MCP_RESOURCES_CHANGED}"
}
