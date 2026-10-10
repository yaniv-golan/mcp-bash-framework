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

@test "sdk_args: get --default applies to a missing or null value" {
	MCP_TOOL_ARGS_JSON='{}'
	assert_equal "World" "$(mcp_args_get '.name' --default 'World')"
	MCP_TOOL_ARGS_JSON='{"name":null}'
	assert_equal "World" "$(mcp_args_get '.name' --default 'World')"
	MCP_TOOL_ARGS_JSON='{"name":""}'
	assert_equal "World" "$(mcp_args_get '.name' --default 'World')"
}

@test "sdk_args: get --default keeps real values" {
	MCP_TOOL_ARGS_JSON='{"name":"Ann","flag":false,"word":"null","n":0}'
	assert_equal "Ann" "$(mcp_args_get '.name' --default 'World')"
	assert_equal "false" "$(mcp_args_get '.flag' --default 'true')"
	assert_equal "null" "$(mcp_args_get '.word' --default 'x')"
	assert_equal "0" "$(mcp_args_get '.n' --default '5')"
	assert_equal '{"a":1}' "$(MCP_TOOL_ARGS_JSON='{"o":{"a":1}}' mcp_args_get '.o' --default '{}')"
}

@test "sdk_args: get without --default is unchanged" {
	MCP_TOOL_ARGS_JSON='{}'
	assert_equal "null" "$(mcp_args_get '.name')"
}

@test "sdk_args: get --default without a value fails" {
	MCP_TOOL_ARGS_JSON='{}'
	run mcp_args_get '.name' --default
	assert_failure
}
