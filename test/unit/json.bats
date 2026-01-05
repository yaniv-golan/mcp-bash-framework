#!/usr/bin/env bats
# Spec §18.2 (Unit layer): validate JSON helpers.

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
		skip "JSON tooling unavailable for normalization test"
	fi
	export MCPBASH_MODE MCPBASH_JSON_TOOL MCPBASH_JSON_TOOL_BIN
}

setup() {
	# Re-source for each test since bats runs tests in subshells
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/json.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
}

@test "json: normalize with jq/gojq" {
	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable"
	fi

	normalized="$(mcp_json_normalize_line $' {"foo":1,\n"bar":2 }\n')"
	assert_equal '{"bar":2,"foo":1}' "${normalized}"
}

@test "json: detect arrays" {
	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable"
	fi

	run mcp_json_is_array '[]'
	assert_success

	run mcp_json_is_array '{"a":1}'
	assert_failure
}

@test "json: minimal mode passthrough and validation" {
	MCPBASH_MODE="minimal"
	minimal="$(mcp_json_normalize_line '{"jsonrpc":"2.0","method":"ping"}')"
	assert_equal '{"jsonrpc":"2.0","method":"ping"}' "${minimal}"

	run mcp_json_normalize_line '{"jsonrpc":2}'
	assert_failure
}

@test "json: BOM and whitespace trimming" {
	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable"
	fi

	bom_line=$'\xEF\xBB\xBF  {"jsonrpc":"2.0","method":"ping"}  \n'
	trimmed="$(MCPBASH_MODE="full" MCPBASH_JSON_TOOL="gojq" MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" mcp_json_normalize_line "${bom_line}")"
	assert_equal '{"jsonrpc":"2.0","method":"ping"}' "${trimmed}"
}
