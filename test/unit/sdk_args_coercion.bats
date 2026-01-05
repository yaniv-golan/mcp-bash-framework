#!/usr/bin/env bats
# Unit layer: argument coercion helpers (mcp_args_bool/int/require).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"

	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable for SDK helper tests"
	fi

	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"
}

@test "sdk_args: bool helper truthy values" {
	MCP_TOOL_ARGS_JSON='{"flag":true}'
	assert_equal "true" "$(mcp_args_bool '.flag')"

	MCP_TOOL_ARGS_JSON='{"flag":1}'
	assert_equal "true" "$(mcp_args_bool '.flag')"
}

@test "sdk_args: bool helper falsy values" {
	MCP_TOOL_ARGS_JSON='{"flag":false}'
	assert_equal "false" "$(mcp_args_bool '.flag')"
}

@test "sdk_args: bool helper default value" {
	MCP_TOOL_ARGS_JSON='{}'
	assert_equal "true" "$(mcp_args_bool '.flag' --default true)"
}

@test "sdk_args: bool helper fails on missing without default" {
	MCP_TOOL_ARGS_JSON='{}'
	run mcp_args_bool '.flag'
	assert_failure
}

@test "sdk_args: int helper with bounds" {
	MCP_TOOL_ARGS_JSON='{"count":5}'
	assert_equal "5" "$(mcp_args_int '.count' --min 1 --max 10)"
}

@test "sdk_args: int helper with negative bounds" {
	MCP_TOOL_ARGS_JSON='{"count":-3}'
	assert_equal "-3" "$(mcp_args_int '.count' --min -5 --max 0)"
}

@test "sdk_args: int helper rejects float" {
	MCP_TOOL_ARGS_JSON='{"count":3.14}'
	run mcp_args_int '.count'
	assert_failure
}

@test "sdk_args: require helper fails on missing" {
	MCP_TOOL_ARGS_JSON='{}'
	run mcp_args_require '.value'
	assert_failure
}

@test "sdk_args: require helper returns value" {
	MCP_TOOL_ARGS_JSON='{"value":"abc"}'
	assert_equal "abc" "$(mcp_args_require '.value')"
}

@test "sdk_args: minimal mode uses defaults" {
	MCPBASH_MODE="minimal"
	MCP_TOOL_ARGS_JSON='{}'
	assert_equal "false" "$(mcp_args_bool '.flag' --default false)"
}

@test "sdk_args: minimal mode fails without default" {
	MCPBASH_MODE="minimal"
	MCP_TOOL_ARGS_JSON='{}'
	run mcp_args_int '.num' --min 0
	assert_failure
}
