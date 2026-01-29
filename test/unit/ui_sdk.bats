#!/usr/bin/env bats
# Unit tests for UI SDK helpers

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
	# shellcheck source=sdk/ui-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/ui-sdk.sh"

	# Also need these for mcp_result_success
	mcp_result_success() {
		local text="$1"
		"${MCPBASH_JSON_TOOL_BIN}" -n --arg text "${text}" '{content: [{type: "text", text: $text}], isError: false}'
	}
}

teardown() {
	[ -d "${TEST_TMPDIR}" ] && rm -rf "${TEST_TMPDIR}"
}

@test "sdk: mcp_client_supports_ui returns false when not set" {
	MCPBASH_CLIENT_SUPPORTS_UI=0
	rm -f "${MCPBASH_STATE_DIR}/extensions.ui.support" 2>/dev/null || true

	run mcp_client_supports_ui
	assert_failure
}

@test "sdk: mcp_client_supports_ui returns true when flag is set" {
	MCPBASH_CLIENT_SUPPORTS_UI=1

	run mcp_client_supports_ui
	assert_success
}

@test "sdk: mcp_client_supports_ui reads from state file" {
	MCPBASH_CLIENT_SUPPORTS_UI=0
	printf '1' > "${MCPBASH_STATE_DIR}/extensions.ui.support"

	run mcp_client_supports_ui
	assert_success
}

@test "sdk: mcp_result_with_ui returns text-only when UI not supported" {
	MCPBASH_CLIENT_SUPPORTS_UI=0
	rm -f "${MCPBASH_STATE_DIR}/extensions.ui.support" 2>/dev/null || true

	result="$(mcp_result_with_ui "ui://server/resource" "Fallback text")"

	# Should be text-only result without _meta.ui
	has_ui="$("${MCPBASH_JSON_TOOL_BIN}" -r '._meta.ui // empty' <<< "${result}")"
	assert_equal "${has_ui}" ""
}

@test "sdk: mcp_result_with_ui includes structuredContent when supported" {
	MCPBASH_CLIENT_SUPPORTS_UI=1

	result="$(mcp_result_with_ui "ui://server/resource" "Fallback text" '{"items": 5}')"

	# Per MCP Apps spec, UI is declared in tool.meta.json, not in results.
	# Results include structuredContent for UI rendering.
	items="$("${MCPBASH_JSON_TOOL_BIN}" -r '.structuredContent.items' <<< "${result}")"
	assert_equal "${items}" "5"
}

@test "sdk: mcp_result_with_ui includes text content" {
	MCPBASH_CLIENT_SUPPORTS_UI=1

	result="$(mcp_result_with_ui "ui://server/resource" "My fallback message")"

	text="$("${MCPBASH_JSON_TOOL_BIN}" -r '.content[0].text' <<< "${result}")"
	assert_equal "${text}" "My fallback message"
}

@test "sdk: mcp_result_with_ui_data includes structured content" {
	MCPBASH_CLIENT_SUPPORTS_UI=1

	result="$(mcp_result_with_ui_data "ui://server/resource" "Text" '{"items": 42}')"

	# Check structuredContent
	items="$("${MCPBASH_JSON_TOOL_BIN}" -r '.structuredContent.items' <<< "${result}")"
	assert_equal "${items}" "42"
}

@test "sdk: mcp_result_with_ui sets isError to false" {
	MCPBASH_CLIENT_SUPPORTS_UI=1

	result="$(mcp_result_with_ui "ui://server/resource" "Text")"

	is_error="$("${MCPBASH_JSON_TOOL_BIN}" -r '.isError' <<< "${result}")"
	assert_equal "${is_error}" "false"
}

@test "sdk: mcp_tool_meta_with_ui generates correct structure" {
	meta="$(mcp_tool_meta_with_ui "ui://server/dashboard")"

	uri="$("${MCPBASH_JSON_TOOL_BIN}" -r '.ui.resourceUri' <<< "${meta}")"
	assert_equal "${uri}" "ui://server/dashboard"

	# Default visibility should include both model and app
	visibility="$("${MCPBASH_JSON_TOOL_BIN}" -r '.ui.visibility | sort | join(",")' <<< "${meta}")"
	assert_equal "${visibility}" "app,model"
}

@test "sdk: mcp_tool_meta_with_ui accepts custom visibility" {
	meta="$(mcp_tool_meta_with_ui "ui://server/admin" "app")"

	visibility="$("${MCPBASH_JSON_TOOL_BIN}" -r '.ui.visibility | join(",")' <<< "${meta}")"
	assert_equal "${visibility}" "app"
}
