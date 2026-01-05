#!/usr/bin/env bats
# Unit layer: SDK JSON helper functions (mcp_json_escape/mcp_json_obj/mcp_json_arr).

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
		skip "JSON tooling unavailable for SDK JSON helper tests"
	fi

	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"
}

@test "sdk_json: escape roundtrip" {
	escaped="$(mcp_json_escape 'value "with" quotes and
newlines')"
	roundtrip="$(printf '%s' "${escaped}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.')"
	assert_equal 'value "with" quotes and
newlines' "${roundtrip}"
}

@test "sdk_json: obj string values" {
	obj="$(mcp_json_obj message 'Hello "World"' count 42)"
	msg="$(printf '%s' "${obj}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.message')"
	count_type="$(printf '%s' "${obj}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.count | type')"
	count_value="$(printf '%s' "${obj}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.count')"

	assert_equal 'Hello "World"' "${msg}"
	assert_equal 'string' "${count_type}"
	assert_equal '42' "${count_value}"
}

@test "sdk_json: arr values" {
	arr="$(mcp_json_arr "one" "two" "three")"
	len="$(printf '%s' "${arr}" | "${MCPBASH_JSON_TOOL_BIN}" 'length')"
	first="$(printf '%s' "${arr}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.[0]')"
	last="$(printf '%s' "${arr}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.[2]')"

	assert_equal '3' "${len}"
	assert_equal 'one' "${first}"
	assert_equal 'three' "${last}"
}

@test "sdk_json: obj odd argument count is fatal" {
	run mcp_json_obj only_key
	assert_failure
}
