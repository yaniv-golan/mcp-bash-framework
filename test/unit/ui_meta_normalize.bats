#!/usr/bin/env bats
# Unit tests for _meta normalization (deprecated format conversion)

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
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/json.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
	# shellcheck source=lib/tools.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/tools.sh"
}

@test "meta: mcp_tools_normalize_meta converts deprecated flat format" {
	# Deprecated format: _meta["ui/resourceUri"]
	local input='{"content":[{"type":"text","text":"result"}],"isError":false,"_meta":{"ui/resourceUri":"ui://server/resource"}}'

	result="$(mcp_tools_normalize_meta "${input}")"

	# Should be converted to nested format
	uri="$("${MCPBASH_JSON_TOOL_BIN}" -r '._meta.ui.resourceUri' <<< "${result}")"
	assert_equal "${uri}" "ui://server/resource"

	# Old key should be removed
	old_key="$("${MCPBASH_JSON_TOOL_BIN}" -r '._meta["ui/resourceUri"] // empty' <<< "${result}")"
	assert_equal "${old_key}" ""
}

@test "meta: mcp_tools_normalize_meta preserves nested format" {
	# Already correct nested format
	local input='{"content":[{"type":"text","text":"result"}],"isError":false,"_meta":{"ui":{"resourceUri":"ui://server/resource"}}}'

	result="$(mcp_tools_normalize_meta "${input}")"

	uri="$("${MCPBASH_JSON_TOOL_BIN}" -r '._meta.ui.resourceUri' <<< "${result}")"
	assert_equal "${uri}" "ui://server/resource"
}

@test "meta: mcp_tools_normalize_meta handles no _meta" {
	local input='{"content":[{"type":"text","text":"result"}],"isError":false}'

	result="$(mcp_tools_normalize_meta "${input}")"

	# Should pass through unchanged
	is_error="$("${MCPBASH_JSON_TOOL_BIN}" -r '.isError' <<< "${result}")"
	assert_equal "${is_error}" "false"
}

@test "meta: mcp_tools_normalize_meta handles empty _meta" {
	local input='{"content":[],"isError":false,"_meta":{}}'

	result="$(mcp_tools_normalize_meta "${input}")"

	# Should pass through unchanged
	meta="$("${MCPBASH_JSON_TOOL_BIN}" -c '._meta' <<< "${result}")"
	assert_equal "${meta}" "{}"
}

@test "meta: mcp_tools_normalize_meta preserves other _meta fields" {
	local input='{"content":[],"isError":false,"_meta":{"ui/resourceUri":"ui://s/r","other":"value"}}'

	result="$(mcp_tools_normalize_meta "${input}")"

	# Should convert ui/resourceUri
	uri="$("${MCPBASH_JSON_TOOL_BIN}" -r '._meta.ui.resourceUri' <<< "${result}")"
	assert_equal "${uri}" "ui://s/r"

	# Should preserve other fields
	other="$("${MCPBASH_JSON_TOOL_BIN}" -r '._meta.other' <<< "${result}")"
	assert_equal "${other}" "value"
}
