#!/usr/bin/env bats
# Unit tests for UI capabilities negotiation

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup_file() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/json.sh
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
	MCPBASH_STATE_DIR="${TEST_TMPDIR}"
	export TEST_TMPDIR MCPBASH_STATE_DIR

	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/json.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
	# shellcheck source=lib/capabilities.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/capabilities.sh"
}

teardown() {
	[ -d "${TEST_TMPDIR}" ] && rm -rf "${TEST_TMPDIR}"
}

@test "capabilities: mcp_extensions_init detects UI support" {
	local client_caps='{"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}}'

	mcp_extensions_init "${client_caps}"

	assert_equal "${MCPBASH_CLIENT_SUPPORTS_UI}" "1"
}

@test "capabilities: mcp_extensions_init detects no UI support" {
	local client_caps='{"tools":{}}'

	mcp_extensions_init "${client_caps}"

	assert_equal "${MCPBASH_CLIENT_SUPPORTS_UI}" "0"
}

@test "capabilities: mcp_client_supports_ui works after init" {
	local client_caps='{"extensions":{"io.modelcontextprotocol/ui":{}}}'

	mcp_extensions_init "${client_caps}"

	run mcp_client_supports_ui
	assert_success
}

@test "capabilities: mcp_client_supports_extension checks specific extension" {
	local client_caps='{"extensions":{"io.modelcontextprotocol/ui":{}}}'

	mcp_extensions_init "${client_caps}"

	run mcp_client_supports_extension "io.modelcontextprotocol/ui"
	assert_success

	run mcp_client_supports_extension "io.modelcontextprotocol/other"
	assert_failure
}

@test "capabilities: mcp_extensions_build_server_capabilities includes UI when supported" {
	local client_caps='{"extensions":{"io.modelcontextprotocol/ui":{}}}'
	mcp_extensions_init "${client_caps}"

	result="$(mcp_extensions_build_server_capabilities)"

	# Should include UI extension
	has_ui="$("${MCPBASH_JSON_TOOL_BIN}" -r '.["io.modelcontextprotocol/ui"] // empty' <<< "${result}")"
	[ -n "${has_ui}" ]
}

@test "capabilities: mcp_extensions_build_server_capabilities excludes UI when not supported" {
	local client_caps='{}'
	mcp_extensions_init "${client_caps}"

	result="$(mcp_extensions_build_server_capabilities)"

	# Should be empty object
	assert_equal "${result}" "{}"
}

@test "capabilities: mcp_extensions_merge_capabilities adds extensions to base" {
	local client_caps='{"extensions":{"io.modelcontextprotocol/ui":{}}}'
	mcp_extensions_init "${client_caps}"

	local base='{"tools":{"listChanged":true}}'
	result="$(mcp_extensions_merge_capabilities "${base}")"

	# Should have both tools and extensions
	has_tools="$("${MCPBASH_JSON_TOOL_BIN}" -r '.tools.listChanged' <<< "${result}")"
	assert_equal "${has_tools}" "true"

	has_ext="$("${MCPBASH_JSON_TOOL_BIN}" -r '.extensions["io.modelcontextprotocol/ui"] // empty' <<< "${result}")"
	[ -n "${has_ext}" ]
}

@test "capabilities: writes state file for subprocess access" {
	local client_caps='{"extensions":{"io.modelcontextprotocol/ui":{}}}'

	mcp_extensions_init "${client_caps}"

	# Check state file was written
	[ -f "${MCPBASH_STATE_DIR}/extensions.ui.support" ]
	content="$(cat "${MCPBASH_STATE_DIR}/extensions.ui.support")"
	assert_equal "${content}" "1"
}

@test "capabilities: server capabilities include correct mimeTypes" {
	local client_caps='{"extensions":{"io.modelcontextprotocol/ui":{}}}'
	mcp_extensions_init "${client_caps}"

	result="$(mcp_extensions_build_server_capabilities)"

	mime="$("${MCPBASH_JSON_TOOL_BIN}" -r '.["io.modelcontextprotocol/ui"].mimeTypes[0]' <<< "${result}")"
	assert_equal "${mime}" "text/html;profile=mcp-app"
}
